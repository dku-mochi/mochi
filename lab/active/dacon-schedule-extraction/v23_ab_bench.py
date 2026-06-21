#!/usr/bin/env python3
"""v22 vs v23 A/B — "나열형 캡처 분해" 블록이 일정 표 분해/recall 을 회복하는가.

후속 실험 (선행: dacon_schedule_bench.py)
-------------------------------------------
선행 측정에서 v22(production ACTIVE_PROMPT)는 dacon 9행 일정 표를 5회 중 4회 todo 1개
("기획서 7.7")로 뭉갰다 — 분해도·recall 붕괴, schedule(결과발표) 0/5. 단 날짜·노이즈내성·
needs_review·precision(지난/제3자 일정 제외)은 멀쩡했다.

본 실험은 production v22 body 에 "나열형 캡처 분해" 블록 1개만 surgical 하게 삽입한 v23 가
(a) 분해/recall 을 회복하면서 (b) v22 의 강점(노이즈/needs_review/precision/날짜)을 안 깨는지,
(c) 단순(나열형 아닌) 캡처를 과분해하지 않는지를 같은 config·같은 이미지로 A/B 측정한다.

프로덕션 충실 재현 (선행과 동일 — drift 0)
-------------------------------------------
- v22 = `ACTIVE_PROMPT.body` 를 production 에서 직접 import (복붙 금지).
- v23 = 그 body 에 아래 _V23_BLOCK 1개만 `.replace()` 로 삽입. 다른 문장은 1바이트도 안 건드린다
  (surgical — diff 가 곧 삽입 블록 하나뿐임을 _assert_surgical 로 런타임 검증).
- function schema / 시간컨텍스트(2026-06-19 15:38 KST) / generation config(temp 0.3,
  max_output_tokens 1024, thinking_budget 0, Vertex AI, finalizeAnalysis mode=ANY, 이미지 inline)
  전부 선행과 동일.

v23 블록 작성 원칙 (skill-creator + Gemini 프롬프팅 가이드 적용)
-----------------------------------------------------------------
task 가 준 기준 블록의 의미·기준은 보존하되, 다음을 적용해 v22 의 문체·톤에 녹였다:
- skill-creator "Generalize, don't overfit / Explain the why / lean / no ALL-CAPS MUST":
  좁은 "X면 Y" 케이스 나열이 아니라 가르는 원리 + why(회수 주체는 모찌). 제외 항목도 금지
  명령이 아니라 "왜 instance 가 아닌지" 이유로 제시.
- Gemini 프롬프팅: v22 의 Markdown `##` 섹션 + em-dash 설명체와 동일한 구조로 통일(일관된
  포맷이 instruction-following 을 돕는다), "무엇을 분해하라"를 먼저, "무엇을 빼라"를 이유와
  함께 뒤에 — positive-first framing. 이미 v22 에 있는 미션("resurface", 다중 instance)에
  자연스럽게 이어 붙여 외래 bolt-on 으로 읽히지 않게 했다.

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/v23_ab_bench.py
"""

import base64
import json
import mimetypes
import os
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from google import genai
from google.genai import types

# --- production 모듈 직접 import (read-only) — prompt/schema/time-ctx drift 0 ---
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE, _FINALIZE_PARAMS
from app.modules.agent.application.orchestrator import _korea_time_context


DACON_IMAGE = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 5
N_REGRESSION_RUNS = 3

# 회귀(과분해) 체크용 단순/단일 의도 캡처 — 표·목록이 아닌 캡처. 파일명에 사람이 적은 라벨 포함.
REGRESSION_DIR = Path("/Users/jun/Downloads/mochi/lab/data/intent-validation")
REGRESSION_IMAGES = [
    # (파일명, 라벨요약, 기대 단순도) — 단일 의도라 v23 가 쪼개면 안 된다.
    ("validation_13_나중에 살 화장품.jpg", "단일 화장품 구매고민(memo)"),
    ("validation_03_공차 할인 이벤트하니까 캡쳐해두고 나중에 가봐야지.jpg", "단일 할인 이벤트(memo)"),
    ("validation_05_기프티콘 나중에 꼭 써야지.jpg", "단일 기프티콘 사용(memo/todo)"),
]

# 재현성: 2026-06-19 (금) 15:38 KST 고정 (선행과 동일).
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))
AGENT_LOCATION = "global"


# ---------------------------------------------------------------------------
# v23 삽입 블록 — task 기준 보존 + v22 문체/skill-creator/Gemini 가이드 적용.
# 앵커: Context 섹션이 "다중 instance"를 설명하고 끝나는 지점 바로 뒤(# Objective 직전).
# ---------------------------------------------------------------------------
_V23_ANCHOR = "type may repeat when the actions differ.\n"

_V23_BLOCK = (
    "type may repeat when the actions differ.\n"
    "\n"
    "## Breaking apart a list-style capture (tables, checklists, multiple deadlines)\n"
    "Some captures don't hold one moment — they lay out a whole table or list of dates and "
    "deadlines (a schedule table, a list of due dates, a round-by-round or phase list). "
    "Summarizing the whole thing in one line and stopping there quietly drops every row the "
    "user might miss — and missing them is exactly what MOCHI exists to prevent, since MOCHI, "
    "not the user, is the one that has to bring each deadline back. So don't collapse such a "
    "capture into a single instance: turn each row the user must personally act on or show up "
    "for into its own instance, so each easy-to-miss deadline can resurface on its own.\n"
    "- Let each row's own nature pick its type, the same way a single capture would: a thing to "
    "submit or finish is a todo (payload.deadline), a moment to attend or check is a schedule "
    "(payload.date/time). Don't force every row into one type just because they share a table.\n"
    "- Making an instance per row does not mean every row. A row earns an instance only if it is "
    "the user's own future action; the rest belong in the summary, not as instances — because an "
    "instance the user can't act on is just noise that buries the ones they can. Three kinds stay "
    "in the summary: rows already in the past (their moment is gone, like any past event), rows "
    "that are someone else's move to make (a third party's or the organizer's voting, judging, "
    "review, or announcement — the user only waits on these), and a single span that merely wraps "
    "the others as background (an umbrella period the individual rows already live inside).\n"
)


def _build_v23_body(v22_body: str) -> str:
    if v22_body.count(_V23_ANCHOR) != 1:
        raise RuntimeError(f"v23 anchor not unique (count={v22_body.count(_V23_ANCHOR)})")
    v23 = v22_body.replace(_V23_ANCHOR, _V23_BLOCK, 1)
    _assert_surgical(v22_body, v23)
    return v23


def _assert_surgical(v22_body: str, v23_body: str) -> None:
    """v23 = v22 + 삽입블록 하나뿐임을 검증 (다른 문장 변형 0)."""
    inserted = _V23_BLOCK[len(_V23_ANCHOR):]  # 앵커 뒤 새로 들어간 부분
    rebuilt = v23_body.replace(inserted, "", 1)
    if rebuilt != v22_body:
        raise RuntimeError("v23 is NOT a pure single-block insertion of v22 (non-surgical drift!)")


def _load_env() -> None:
    env_path = Path(__file__).resolve().parents[3] / "mochi-backend" / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if k in ("GOOGLE_CLOUD_PROJECT", "GEMINI_MODEL") and k not in os.environ:
            os.environ[k] = v


def _build_user_message() -> str:
    blocks = [
        _korea_time_context(PINNED_NOW),
        "첨부된 스크린샷/이미지를 함께 분석하세요.",
    ]
    return "\n\n".join(blocks)


def _image_part(path: Path) -> types.Part:
    mime = mimetypes.guess_type(str(path))[0] or "image/png"
    data = path.read_bytes()
    return types.Part.from_bytes(data=data, mime_type=mime)


def _finalize_declaration() -> types.FunctionDeclaration:
    return types.FunctionDeclaration(
        name=_FINALIZE,
        description="Emit the final structured analysis. Call exactly once when ready.",
        parameters=_FINALIZE_PARAMS,
    )


def _extract_finalize_args(resp) -> dict | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None) == _FINALIZE:
                return dict(fc.args or {})
    return None


def run_once(client: genai.Client, model: str, system_prompt: str, image: Path) -> dict:
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=1024,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        tools=[types.Tool(function_declarations=[_finalize_declaration()])],
        tool_config=types.ToolConfig(
            function_calling_config=types.FunctionCallingConfig(mode="ANY")
        ),
    )
    contents = [
        types.Content(role="user", parts=[types.Part(text=_build_user_message()), _image_part(image)])
    ]
    t0 = time.perf_counter()
    resp = client.models.generate_content(model=model, contents=contents, config=cfg)
    latency_ms = round((time.perf_counter() - t0) * 1000, 1)
    args = _extract_finalize_args(resp)
    if args is None:
        return {"latency_ms": latency_ms, "error": "no finalizeAnalysis call",
                "raw_text": getattr(resp, "text", None)}
    return {"latency_ms": latency_ms, "output": args}


# ---------------------------------------------------------------------------
# 8축 채점 — dacon 골든 기대치 기반 (선행 scoring.json 의 규칙을 코드로 명문화).
# 핵심3(잡아야 함):  기획서(todo 07-07), 산출물(todo 07-15), 결과발표(schedule 07-27).
# 금지5(만들면 과생성): 참가접수(지난), 대회기간(우산 span), 예선평가/투표(제3자),
#                       본선진출팀 안내(운영측 공지), 자료검증(운영측).
#   ※ '본선 발표자료 제출 기간'(7.17~7.20)은 본선 진출 조건부라 core/금지 어디도 아님(중립).
# ---------------------------------------------------------------------------
CORE = {
    "기획서": {"kw": ["기획서"], "type": "todo", "date_field": "deadline", "date": "2026-07-07"},
    "산출물": {"kw": ["산출물"], "type": "todo", "date_field": "deadline", "date": "2026-07-15"},
    "결과발표": {"kw": ["결과발표", "결과 발표", "예선 결과"], "type": "schedule",
              "date_field": "date", "date": "2026-07-27"},
}
FORBIDDEN = {
    "참가접수(지난)": ["참가접수", "참가 접수", "참가신청", "참가 신청"],
    "대회기간(우산span)": ["대회기간", "대회 기간", "참가 기간", "대회 참가"],
    "예선평가/투표(제3자)": ["예선평가", "예선 평가", "투표"],
    "본선진출팀안내(운영측)": ["발표자료 제출 안내", "진출팀 및 발표", "진출팀 안내"],
    "자료검증(운영측)": ["자료 검증", "자료검증", "검증"],
}


def _inst_text(ins: dict) -> str:
    p = ins.get("payload", {})
    return " ".join(str(x) for x in [
        p.get("title", ""), ins.get("label", ""), ins.get("reasoning", ""),
        p.get("note", ""),
    ])


def _date_of(ins: dict) -> str:
    p = ins.get("payload", {})
    raw = p.get("deadline") or p.get("date") or ""
    return raw[:10] if raw else ""


def score_dacon(output: dict) -> dict:
    insts = output.get("intent_instances", []) or []
    n = len(insts)

    # Recall: 핵심3 각각 적어도 1 instance 가 잡았나 (키워드 매칭).
    recall_hits = {}
    for name, spec in CORE.items():
        hit = None
        for ins in insts:
            txt = _inst_text(ins)
            if any(k in txt for k in spec["kw"]):
                hit = ins
                break
        recall_hits[name] = hit
    recall = sum(1 for v in recall_hits.values() if v is not None)

    # 과생성: 금지5 중 instance 로 만든 것.
    over = []
    for name, kws in FORBIDDEN.items():
        for ins in insts:
            if any(k in _inst_text(ins) for k in kws):
                over.append(name)
                break

    # span 오용: end_date 채운 instance 가 있는가 (대회기간 같은 우산 span 을 instance 화).
    span_misuse = any(ins.get("payload", {}).get("end_date") for ins in insts)

    # 날짜 정확도 + type 정확도: 잡은 핵심3 에 한해.
    date_check = {}
    type_ok = True
    for name, ins in recall_hits.items():
        if ins is None:
            continue
        spec = CORE[name]
        got_date = _date_of(ins)
        got_type = ins.get("intent_type")
        date_ok = got_date == spec["date"]
        date_check[name] = [got_date or "(empty)", date_ok]
        if got_type != spec["type"]:
            type_ok = False
    date_accuracy = all(v[1] for v in date_check.values()) if date_check else False

    # 노이즈 내성: dacon.io UI/탭/D-11/58%할인 등 화면 노이즈를 instance 로 끌어들였나.
    noise_kw = ["dacon.io", "데이스쿨", "할인", "리턴즈", "참가신청 대기", "D-11", "58%", "커뮤니티", "더보기"]
    noise = any(any(k in _inst_text(ins) for k in noise_kw) for ins in insts)

    return {
        "n": n,
        "recall": recall,
        "recall_detail": {k: (v is not None) for k, v in recall_hits.items()},
        "over": over,
        "span_misuse": span_misuse,
        "date_accuracy": date_accuracy,
        "date_check": date_check,
        "type_ok": type_ok,
        "noise": noise,
        "needs_review": output.get("needs_review"),
        "category": output.get("category"),
    }


def run_arm(client, model, body, label) -> list[dict]:
    runs = []
    print(f"\n=== ARM {label}  (prompt_len={len(body)}) ===", file=sys.stderr)
    for i in range(1, N_RUNS + 1):
        try:
            r = run_once(client, model, body, DACON_IMAGE)
        except Exception as e:  # noqa: BLE001
            r = {"error": f"{type(e).__name__}: {e}"}
        r["run"] = i
        (RESULTS_DIR / f"{label}_run_{i}.json").write_text(json.dumps(r, ensure_ascii=False, indent=2))
        if "output" in r:
            out = r["output"]
            sc = score_dacon(out)
            r["score"] = sc
            insts = out.get("intent_instances", [])
            print(f"[{label} run {i}] {r.get('latency_ms')}ms  n={sc['n']}  recall={sc['recall']}/3 "
                  f"over={sc['over']}  span={sc['span_misuse']}  date_ok={sc['date_accuracy']}  "
                  f"type_ok={sc['type_ok']}  noise={sc['noise']}  nr={sc['needs_review']}", file=sys.stderr)
            for ins in insts:
                p = ins.get("payload", {})
                d = p.get("date") or p.get("deadline") or "-"
                if p.get("time"):
                    d = f"{d} {p['time']}"
                if p.get("end_date"):
                    d = f"{d} ~ {p['end_date']}"
                print(f"     - {str(ins.get('intent_type')):8s} | {str(p.get('title','?'))[:30]:30s} | {d}",
                      file=sys.stderr)
        else:
            print(f"[{label} run {i}] ERROR: {r.get('error')}", file=sys.stderr)
        runs.append(r)
    return runs


def run_regression(client, model, v22_body, v23_body) -> list[dict]:
    print("\n=== REGRESSION (단순 캡처 과분해 체크) ===", file=sys.stderr)
    rows = []
    for fname, desc in REGRESSION_IMAGES:
        img = REGRESSION_DIR / fname
        entry = {"image": fname, "desc": desc, "v22_counts": [], "v23_counts": [],
                 "v22_runs": [], "v23_runs": []}
        if not img.exists():
            entry["error"] = "image not found"
            rows.append(entry)
            print(f"  [SKIP] {fname} not found", file=sys.stderr)
            continue
        for body, key in ((v22_body, "v22"), (v23_body, "v23")):
            for j in range(1, N_REGRESSION_RUNS + 1):
                try:
                    r = run_once(client, model, body, img)
                except Exception as e:  # noqa: BLE001
                    r = {"error": f"{type(e).__name__}: {e}"}
                if "output" in r:
                    insts = r["output"].get("intent_instances", []) or []
                    entry[f"{key}_counts"].append(len(insts))
                    entry[f"{key}_runs"].append({
                        "n": len(insts),
                        "types": [x.get("intent_type") for x in insts],
                        "titles": [x.get("payload", {}).get("title") for x in insts],
                    })
                else:
                    entry[f"{key}_counts"].append(None)
                    entry[f"{key}_runs"].append({"error": r.get("error")})
        v22c = [c for c in entry["v22_counts"] if c is not None]
        v23c = [c for c in entry["v23_counts"] if c is not None]
        entry["v22_avg"] = round(sum(v22c) / len(v22c), 2) if v22c else None
        entry["v23_avg"] = round(sum(v23c) / len(v23c), 2) if v23c else None
        print(f"  {desc[:24]:24s}  v22 n={entry['v22_counts']} (avg {entry['v22_avg']})  "
              f"v23 n={entry['v23_counts']} (avg {entry['v23_avg']})", file=sys.stderr)
        rows.append(entry)
    return rows


def aggregate(runs: list[dict]) -> dict:
    scored = [r["score"] for r in runs if "score" in r]
    if not scored:
        return {"error": "no scored runs"}
    def maj(key):
        c = Counter(s[key] for s in scored)
        return c.most_common(1)[0][0]
    core_caught = {name: sum(1 for s in scored if s["recall_detail"].get(name)) for name in CORE}
    return {
        "n_scored": len(scored),
        "n_instances_mean": round(sum(s["n"] for s in scored) / len(scored), 2),
        "recall_mean": round(sum(s["recall"] for s in scored) / len(scored), 2),
        "core_caught_out_of_n": {k: f"{v}/{len(scored)}" for k, v in core_caught.items()},
        "over_gen_runs": sum(1 for s in scored if s["over"]),
        "over_gen_items": dict(Counter(x for s in scored for x in s["over"])),
        "span_misuse_runs": sum(1 for s in scored if s["span_misuse"]),
        "date_accuracy_runs": f"{sum(1 for s in scored if s['date_accuracy'])}/{len(scored)}",
        "type_ok_runs": f"{sum(1 for s in scored if s['type_ok'])}/{len(scored)}",
        "noise_runs": sum(1 for s in scored if s["noise"]),
        "needs_review_majority": maj("needs_review"),
    }


def main() -> int:
    _load_env()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    model = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite")
    if not project:
        print("BLOCKER: GOOGLE_CLOUD_PROJECT not found", file=sys.stderr)
        return 2
    if not DACON_IMAGE.exists():
        print(f"BLOCKER: dacon image not found: {DACON_IMAGE}", file=sys.stderr)
        return 2

    v22_body = ACTIVE_PROMPT.body
    v23_body = _build_v23_body(v22_body)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    # v23 프롬프트 문자열 + 삽입 블록 산출물로 저장 (반영 시 참조).
    (RESULTS_DIR / "v23_prompt.txt").write_text(v23_body)
    (RESULTS_DIR / "v23_inserted_block.txt").write_text(_V23_BLOCK[len(_V23_ANCHOR):])

    print(f"model={model}  base={ACTIVE_PROMPT.name}  transport=vertex/{AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"v22_len={len(v22_body)}  v23_len={len(v23_body)}  delta=+{len(v23_body)-len(v22_body)}",
          file=sys.stderr)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)

    v22_runs = run_arm(client, model, v22_body, "v22")
    v23_runs = run_arm(client, model, v23_body, "v23")
    regression = run_regression(client, model, v22_body, v23_body)

    agg = {"v22": aggregate(v22_runs), "v23": aggregate(v23_runs)}
    print("\n=== AGGREGATE ===", file=sys.stderr)
    print(json.dumps(agg, ensure_ascii=False, indent=2), file=sys.stderr)

    summary = {
        "meta": {
            "model": model,
            "base_prompt": ACTIVE_PROMPT.name,
            "v23": "v22 + single inserted block (나열형 캡처 분해), surgical-verified",
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs_per_arm": N_RUNS,
            "n_regression_runs": N_REGRESSION_RUNS,
            "dacon_image": str(DACON_IMAGE),
            "client": f"vertex(project,location={AGENT_LOCATION})_inline_base64",
            "v22_len": len(v22_body),
            "v23_len": len(v23_body),
        },
        "aggregate": agg,
        "dacon": {"v22": v22_runs, "v23": v23_runs},
        "regression": regression,
    }
    (RESULTS_DIR / "v23_ab_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULTS_DIR}/v23_ab_summary.json + v22_run_*.json + v23_run_*.json + v23_prompt.txt",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
