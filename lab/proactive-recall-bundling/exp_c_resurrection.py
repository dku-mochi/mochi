"""실험 C — 라벨 소생(window 밖).

같은 주제 item 이 시간상 멀리 떨어진 시나리오를 만든다(테마 멤버들을 시퀀스
앞뒤로 강제 분산). 두 묶음 전략을 비교:

  (1) window-only: 최근 M(=10)개 item 만 후보로 본다. 기존 라벨이 window 밖이면
      못 보고 → 새 라벨을 또 만든다(중복).
  (2) label-ANN: 라벨 centroid 전체를 ANN(전수 cosine)으로 검색해 sim>=THETA 면
      소환해 붙인다. window 무관.

지표: 같은 ground-truth theme 에 대해 생성된 라벨 수(=중복 생성 수). 1이 이상.
묶음 판단 자체는 'ground-truth theme 일치' 라는 오라클로 고정(LLM 품질과 분리).
ANN 의 소환은 centroid cosine 으로 한다(실제로 라벨 임베딩이 그 수단).
"""

from __future__ import annotations

import json
import os

import numpy as np

from common import Item, load_items, theme_of

OUT = os.path.join(os.path.dirname(__file__), "exp_c_results.json")
WINDOW_M = 10
ANN_THETA = 0.62  # 라벨 centroid 소환 임계 (실험 A 에서 본 dense space 임계)


def scatter_order(items: list[Item]) -> list[Item]:
    """같은 theme 멤버들을 window(M) 보다 멀리 떨어뜨린 시퀀스를 만든다.
    각 theme 의 같은-멤버 간격이 M 을 넘도록 theme 별로 stride 를 크게 배치한다."""
    themed: dict[str, list[Item]] = {}
    rest: list[Item] = []
    for i in items:
        t = theme_of(i)
        if t:
            themed.setdefault(t, []).append(i)
        else:
            rest.append(i)
    n = len(items)
    slots: list[Item | None] = [None] * n
    placed: set[str] = set()
    # 각 theme 멤버를 전체 길이에 균등 분산 → 같은 theme 인접 간격 ≈ n/멤버수 (>> M)
    for t, lst in themed.items():
        stride = max(WINDOW_M + 2, n // len(lst)) if len(lst) > 1 else n
        # theme 별 시작 오프셋을 다르게 줘 theme 끼리 겹치지 않게
        offset = (hash(t) % WINDOW_M)
        for k, it in enumerate(lst):
            p = (offset + k * stride) % n
            tries = 0
            while slots[p] is not None and tries < n:
                p = (p + 1) % n
                tries += 1
            slots[p] = it
            placed.add(it.item_id)
    # 나머지(themeless) 채우기
    ri = 0
    for p in range(n):
        if slots[p] is None:
            while ri < len(items) and items[ri].item_id in placed:
                ri += 1
            if ri < len(items):
                slots[p] = items[ri]
                placed.add(items[ri].item_id)
                ri += 1
    return [s for s in slots if s is not None]


def _bundle(seq: list[Item], use_ann: bool) -> dict:
    """오라클 묶음기(theme 일치)로 라벨을 누적하되, 후보 가시성만 전략에 따라 다르게."""
    # 라벨: theme -> list of label-instances(각 centroid 보유)
    labels: list[dict] = []  # {theme, centroid, sum, members}
    for pos, it in enumerate(seq):
        t = theme_of(it)
        if t is None:
            continue  # themeless 는 무시(중복 측정 대상 아님)
        if use_ann:
            visible = labels  # 전수 ANN
        else:
            # window-only: 최근 WINDOW_M 개 안에 멤버가 있는 라벨만 보임
            recent_ids = {x.item_id for x in seq[max(0, pos - WINDOW_M) : pos]}
            visible = [l for l in labels if recent_ids & set(l["members"])]
        # 후보 중 같은 theme + centroid sim>=THETA 면 배정
        best = None
        best_sim = -1.0
        for l in visible:
            sim = float(np.dot(it.vec, l["centroid"]))
            if l["theme"] == t and sim >= ANN_THETA and sim > best_sim:
                best, best_sim = l, sim
        if best is None:
            lab = {"theme": t, "sum": it.vec.copy(), "members": [it.item_id]}
            lab["centroid"] = lab["sum"] / (np.linalg.norm(lab["sum"]) + 1e-9)
            labels.append(lab)
        else:
            best["members"].append(it.item_id)
            best["sum"] = best["sum"] + it.vec
            best["centroid"] = best["sum"] / (np.linalg.norm(best["sum"]) + 1e-9)

    # theme 별 생성된 라벨 수
    per_theme: dict[str, int] = {}
    for l in labels:
        per_theme[l["theme"]] = per_theme.get(l["theme"], 0) + 1
    return per_theme


def run() -> dict:
    items = load_items()
    seq = scatter_order(items)
    # 각 theme 의 멤버가 실제로 얼마나 흩어졌나(평균 인접 간격) 측정
    pos = {it.item_id: i for i, it in enumerate(seq)}
    spreads = {}
    for t in set(theme_of(i) for i in items if theme_of(i)):
        ps = sorted(pos[i.item_id] for i in items if theme_of(i) == t)
        gaps = [ps[k + 1] - ps[k] for k in range(len(ps) - 1)]
        spreads[t] = {"positions": ps, "avg_gap": round(np.mean(gaps), 1) if gaps else 0}

    window = _bundle(seq, use_ann=False)
    ann = _bundle(seq, use_ann=True)

    # ground-truth: theme 당 라벨 1개가 이상. 중복 = 생성수 - 1
    themes = sorted(set(theme_of(i) for i in items if theme_of(i)))
    table = []
    for t in themes:
        table.append(
            {
                "theme": t,
                "gt_members": sum(1 for i in items if theme_of(i) == t),
                "avg_position_gap": spreads[t]["avg_gap"],
                "window_only_labels": window.get(t, 0),
                "label_ann_labels": ann.get(t, 0),
            }
        )
    return {
        "window_M": WINDOW_M,
        "ann_theta": ANN_THETA,
        "note": "오라클 묶음(theme 일치)으로 전략만 비교. 라벨 중복 생성 수 측정.",
        "per_theme": table,
        "totals": {
            "window_only_total_labels": sum(window.values()),
            "label_ann_total_labels": sum(ann.values()),
            "ideal_total_labels": len(themes),
        },
    }


if __name__ == "__main__":
    result = run()
    with open(OUT, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"wrote {OUT}")
    print(f"  window M={result['window_M']} theta={result['ann_theta']}")
    print(f"  {'theme':14s} {'mem':>3s} {'gap':>5s} {'win#':>5s} {'ann#':>5s}")
    for r in result["per_theme"]:
        print(
            f"  {r['theme']:14s} {r['gt_members']:>3d} {r['avg_position_gap']:>5.1f} "
            f"{r['window_only_labels']:>5d} {r['label_ann_labels']:>5d}"
        )
    t = result["totals"]
    print(
        f"  TOTAL labels: window-only={t['window_only_total_labels']} "
        f"label-ANN={t['label_ann_total_labels']} ideal={t['ideal_total_labels']}"
    )
