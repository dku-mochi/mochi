"""규칙 baseline — importance(1~5) + days_until 만으로 무게/리드스케줄을 정한다.

이 규칙이 "공짜 신호(importance)만으로 충분한가"의 대조군이다. LLM 의미판단과 비교해
어디서 갈리는지 본다.

규칙 (부모 제안 골격을 그대로 채택 + 한 줄 근거):
  - importance 5  또는 days_until > 14  → heavy : [D-14, D-7, D-3, D-1]
  - importance 3~4                       → medium: [D-3, D-1]
  - importance 1~2                       → light : [D-1]
  근거: importance 는 기존 LLM 이 캡처 시점에 매긴 "중요도" 신호로 이미 존재(공짜).
       days_until>14 를 heavy 로 끌어올린 건 "먼 일정도 일찍 알려야 하는 게 있다"는 직관 반영
       (단발로 끝내면 잊힘). 이 규칙이 importance 의 한계를 얼마나 가리는지가 관전 포인트.

리드스케줄은 이미 지난 단계(days_until 보다 큰 D-n)는 자동 누락 — "오늘 기준 앞으로 칠
알림"만 남긴다. (예: days_until=2 인데 heavy 면 [D-14,D-7,D-3] 은 이미 지났으니 [D-1]만 발화)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from prep import load_cases  # noqa: E402

LEAD_BY_WEIGHT = {
    "heavy": [14, 7, 3, 1],
    "medium": [3, 1],
    "light": [1],
}


def rule_weight(importance: int | None, days_until: int | None) -> str:
    imp = importance if importance is not None else 3  # 결측은 중립
    far = days_until is not None and days_until > 14
    if imp >= 5 or far:
        return "heavy"
    if imp >= 3:
        return "medium"
    return "light"


def fireable_leads(weight: str, days_until: int | None) -> list[str]:
    """무게가 정한 [D-n...] 중, 오늘 기준 아직 안 지난 것만 (days_until 이상인 D-n)."""
    leads = LEAD_BY_WEIGHT[weight]
    if days_until is None:
        return [f"D-{n}" for n in leads]
    fire = [n for n in leads if n <= days_until] if days_until > 0 else []
    # days_until==0(오늘 마감)/음수(지남)면 D-1 도 못 침 → 즉시(D-0) 한 번으로 처리
    if days_until is not None and days_until <= 0:
        return ["D-0(즉시)"]
    if not fire and days_until is not None and days_until >= 1:
        # 모든 예정 단계가 지났지만 아직 마감 전 → 최소 D-1 보장
        return ["D-1"]
    return [f"D-{n}" for n in fire]


def run() -> list[dict]:
    out = []
    for c in load_cases():
        w = rule_weight(c["importance"], c["days_until"])
        out.append(
            {
                **c,
                "rule_weight": w,
                "rule_full_schedule": [f"D-{n}" for n in LEAD_BY_WEIGHT[w]],
                "rule_fireable": fireable_leads(w, c["days_until"]),
            }
        )
    return out


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    rows = run()
    out_path = Path(__file__).parent / "results" / "rule_baseline.json"
    out_path.parent.mkdir(exist_ok=True)
    out_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    from collections import Counter

    wc = Counter(r["rule_weight"] for r in rows)
    print(f"규칙 무게 분포: {dict(wc)}  (총 {len(rows)}건)\n")
    print(f"{'imp':>3} {'days':>5} {'weight':7} {'full':20} title")
    for r in sorted(rows, key=lambda x: (x["days_until"] if x["days_until"] is not None else 999)):
        print(
            f"{str(r['importance']):>3} {str(r['days_until']):>5} {r['rule_weight']:7} "
            f"{str(r['rule_full_schedule']):20} {r['title'][:40]}"
        )
    print(f"\n저장: {out_path}")
