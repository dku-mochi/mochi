"""실험 A — LLM sliding-window batch 묶음 시뮬레이션.

설계안: embedding prefilter → LLM batch(기존 라벨 시드)로 entity 기반 묶음을 증분 업데이트.

온라인 시나리오:
- item 을 파일순(=대략 도착순)으로 BATCH_SIZE 개씩 투입.
- batch 안 신규 item 각각에 대해:
  · 기존 라벨 centroid 와의 cosine 으로 top-K 후보만 좁힌다(prefilter).
  · LLM(flash-lite) 에게 "후보 라벨에 배정 vs 새 라벨 생성" 을 시킨다.
    입력: 신규 item 의 entity_text(shopping_product + summary) + 후보 라벨 목록.
  · 라벨은 영속 dict 로 누적. 배정되면 centroid 갱신, 새로 만들면 라벨 생성.
- LLM 불가 시: cosine 임계 규칙 시뮬(가장 가까운 라벨 sim>=THETA 면 배정, 아니면 신규).

산출: 최종 라벨 목록 + member, HDBSCAN/ground-truth 정합성.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field

import numpy as np

from common import Item, load_items, theme_of

BATCH_SIZE = 3
TOP_K = 5  # prefilter 후보 라벨 수
THETA = 0.62  # 규칙 시뮬 fallback 코사인 임계 (정규화 voyage emb)
OUT = os.path.join(os.path.dirname(__file__), "exp_a_results.json")


@dataclass
class Label:
    name: str
    members: list[str] = field(default_factory=list)  # item_ids
    centroid: np.ndarray | None = None
    _sum: np.ndarray | None = None

    def add(self, item: Item) -> None:
        self.members.append(item.item_id)
        self._sum = item.vec.copy() if self._sum is None else self._sum + item.vec
        c = self._sum / len(self.members)
        self.centroid = c / (np.linalg.norm(c) + 1e-9)


# ---------------- LLM 배정/명명 ----------------

_GENAI = None


def _llm_available() -> bool:
    global _GENAI
    if _GENAI is not None:
        return _GENAI is not False
    try:
        sys.path.insert(0, "/Users/jun/Downloads/mochi/mochi-backend")
        from google import genai  # noqa: PLC0415
        from app.core.config import get_settings  # noqa: PLC0415

        s = get_settings()
        if not s.google_cloud_project:
            _GENAI = False
            return False
        client = genai.Client(
            vertexai=True, project=s.google_cloud_project, location=s.gemini_agent_location
        )
        _GENAI = (client, s.gemini_agent_model)
        return True
    except Exception as e:  # noqa: BLE001
        print(f"[llm] unavailable: {e}", file=sys.stderr)
        _GENAI = False
        return False


def _llm_assign(item: Item, candidates: list[Label]) -> dict:
    """flash-lite 에 배정/명명 판단을 시킨다. 반환: {action, label, name}."""
    from google.genai import types  # noqa: PLC0415

    client, model = _GENAI
    cand_lines = (
        "\n".join(f"{i+1}. {c.name}" for i, c in enumerate(candidates))
        if candidates
        else "(없음)"
    )
    prompt = (
        "당신은 사용자의 저장 기록을 '주제 묶음(라벨)' 으로 정리하는 모듈이다.\n"
        "새 기록 하나가 들어왔다. 아래 기존 라벨 후보 중 같은 주제가 있으면 그 라벨에 배정하고,\n"
        "없으면 이 기록을 대표하는 짧은 새 라벨명을 만들어라.\n"
        "라벨은 '같은 브랜드/같은 종목/같은 주제' 수준의 구체적 묶음이다 "
        "(예: '유니클로', '헨리넥 티셔츠', '투자 관심종목', '청년안심주택'). "
        "너무 넓은 카테고리(쇼핑/일상)로 묶지 마라.\n\n"
        f"[새 기록]\n{item.entity_text}\n\n"
        f"[기존 라벨 후보]\n{cand_lines}\n\n"
        'JSON 으로만 답하라: {"action":"assign"|"new", '
        '"label_index": <assign일때 후보번호 1-base, 아니면 null>, '
        '"new_name": <new일때 새 라벨명, 아니면 null>}'
    )
    cfg = types.GenerateContentConfig(
        system_instruction="You return only JSON.",
        temperature=0.0,
        max_output_tokens=128,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        response_mime_type="application/json",
    )
    r = client.models.generate_content(model=model, contents=prompt, config=cfg)
    try:
        d = json.loads(r.text)
    except (json.JSONDecodeError, TypeError):
        return {"action": "new", "name": (item.shopping[0] if item.shopping else item.category)}
    if d.get("action") == "assign" and d.get("label_index"):
        idx = int(d["label_index"]) - 1
        if 0 <= idx < len(candidates):
            return {"action": "assign", "label": candidates[idx]}
    name = d.get("new_name") or (item.shopping[0] if item.shopping else item.category)
    return {"action": "new", "name": name}


def _rule_assign(item: Item, candidates: list[Label]) -> dict:
    """LLM fallback: 가장 가까운 후보 sim>=THETA 면 배정, 아니면 신규."""
    best, best_sim = None, -1.0
    for c in candidates:
        sim = float(np.dot(item.vec, c.centroid))
        if sim > best_sim:
            best, best_sim = c, sim
    if best is not None and best_sim >= THETA:
        return {"action": "assign", "label": best}
    name = item.shopping[0] if item.shopping else item.category
    return {"action": "new", "name": name}


def run(use_llm: bool) -> dict:
    items = load_items()
    labels: list[Label] = []
    assigner = _llm_assign if use_llm else _rule_assign
    n_calls = 0

    for start in range(0, len(items), BATCH_SIZE):
        batch = items[start : start + BATCH_SIZE]
        for it in batch:
            # prefilter: 기존 라벨 centroid 와 cosine top-K
            scored = sorted(
                labels, key=lambda c: float(np.dot(it.vec, c.centroid)), reverse=True
            )
            cands = scored[:TOP_K]
            n_calls += 1
            res = assigner(it, cands)
            if res["action"] == "assign":
                res["label"].add(it)
            else:
                lab = Label(name=res["name"])
                lab.add(it)
                labels.append(lab)

    return _score(items, labels, use_llm, n_calls)


def _score(items: list[Item], labels: list[Label], use_llm: bool, n_calls: int) -> dict:
    by_id = {i.item_id: i for i in items}
    multi = [l for l in labels if len(l.members) >= 2]

    # 정합성: 각 ground-truth 주제가 몇 개 라벨에 흩어졌나 + 한 라벨에 깨끗이 모였나
    theme_members: dict[str, set[str]] = {}
    for i in items:
        t = theme_of(i)
        if t:
            theme_members.setdefault(t, set()).add(i.item_id)

    theme_report = {}
    for theme, gt_ids in theme_members.items():
        # 이 주제 item 들이 속한 라벨들
        covering = {}
        for lab in labels:
            hit = gt_ids & set(lab.members)
            if hit:
                covering[lab.name] = len(hit)
        # 가장 큰 커버 라벨의 purity (그 라벨 안에서 이 주제 비율)
        if covering:
            main = max(covering, key=covering.get)
            main_lab = next(l for l in labels if l.name == main)
            purity = covering[main] / len(main_lab.members)
        else:
            main, purity = None, 0.0
        theme_report[theme] = {
            "gt_size": len(gt_ids),
            "n_labels_spread": len(covering),  # 1 이면 안 흩어짐(좋음)
            "main_label": main,
            "main_label_total": len(next(l for l in labels if l.name == main).members)
            if main
            else 0,
            "main_label_captured": covering.get(main, 0),
            "main_label_purity": round(purity, 2),
        }

    label_dump = [
        {
            "name": l.name,
            "size": len(l.members),
            "themes": sorted({theme_of(by_id[m]) for m in l.members if theme_of(by_id[m])}),
            "sample": [by_id[m].summary[:34] for m in l.members[:3]],
        }
        for l in sorted(labels, key=lambda x: -len(x.members))
    ]

    return {
        "mode": "LLM(flash-lite)" if use_llm else "RULE(cosine>=%.2f)" % THETA,
        "n_items": len(items),
        "n_llm_calls": n_calls,
        "n_labels_total": len(labels),
        "n_labels_multi": len(multi),
        "n_singletons": len(labels) - len(multi),
        "theme_consistency": theme_report,
        "labels": label_dump,
    }


if __name__ == "__main__":
    use_llm = _llm_available()
    print(f"LLM available: {use_llm}")
    result = run(use_llm)
    # 비교용으로 규칙 시뮬도 항상 함께 돌린다(LLM 사용 시)
    if use_llm:
        result = {"llm": result, "rule": run(False)}
    with open(OUT, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"wrote {OUT}")
    top = result["llm"] if use_llm else result
    print(json.dumps(top["theme_consistency"], ensure_ascii=False, indent=2))
    print(f"labels total={top['n_labels_total']} multi={top['n_labels_multi']}")
