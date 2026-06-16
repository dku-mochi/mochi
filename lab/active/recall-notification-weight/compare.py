"""규칙 baseline vs LLM 무게 판정 비교 — importance 만으로 충분한가의 증거를 모은다.

핵심은 정량 일치도가 아니라:
  (1) 규칙 vs LLM 이 갈리는 케이스 (무게 불일치)
  (2) "importance 가 무게의 좋은 신호인가"의 반례:
       - importance 낮은데 사실 무거운 일 (먼 중요 일정)
       - importance 높은데 사실 D-1 한 번으로 충분한 일
  (3) LLM 자체의 안정성 — 거의 같은 일(중복/유사 title)에 무게가 흔들리나

입력: results/rule_baseline.json + results/llm_judge_latest.json
출력: results/comparison.json (FINDINGS.md 가 이걸 인용)
"""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

RESULTS = Path(__file__).parent / "results"
WEIGHT_ORDER = {"light": 0, "medium": 1, "heavy": 2}


def load(name: str) -> list[dict]:
    return json.loads((RESULTS / name).read_text(encoding="utf-8"))


def main() -> None:
    rule = {r["key"]: r for r in load("rule_baseline.json")}
    llm = {r["key"]: r for r in load("llm_judge_latest.json")}

    rows = []
    for k, r in rule.items():
        l = llm.get(k, {})
        rw, lw = r["rule_weight"], l.get("llm_weight")
        rows.append(
            {
                "key": k,
                "title": r["title"],
                "intent_type": r["intent_type"],
                "importance": r["importance"],
                "days_until": r["days_until"],
                "rule_weight": rw,
                "llm_weight": lw,
                "agree": rw == lw,
                "llm_schedule": l.get("llm_schedule"),
                "llm_reasoning": l.get("llm_reasoning"),
            }
        )

    n = len(rows)
    agree = sum(1 for r in rows if r["agree"])

    # (1) 불일치 케이스
    disagree = [r for r in rows if not r["agree"]]

    # (2) importance 가 나쁜 신호인 반례:
    #   A. importance 5(규칙=heavy 강제)인데 LLM 은 light/medium (= D-1 한두 번이면 충분)
    high_imp_but_light = [
        r for r in rows
        if r["importance"] == 5 and r["llm_weight"] in ("light", "medium")
    ]
    #   B. importance 낮음(<=3)인데 LLM 은 heavy (= 먼/큰 일, 일찍 알려야)
    low_imp_but_heavy = [
        r for r in rows
        if (r["importance"] is not None and r["importance"] <= 3) and r["llm_weight"] == "heavy"
    ]

    # (3) LLM 안정성: 같은(또는 거의 같은) 과제가 중복으로 들어있다 — title 정규화로 그룹
    def norm(t: str) -> str:
        return (
            t.replace("Submission", "").replace("서비스 ", "").replace(" 제출", "")
            .replace("(2026-06-28)", "").strip().lower()
        )

    groups: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        groups[norm(r["title"])].append(r)
    inconsistent_groups = []
    for key, grp in groups.items():
        if len(grp) > 1:
            weights = {g["llm_weight"] for g in grp}
            if len(weights) > 1:
                inconsistent_groups.append(
                    {"title_norm": key, "n": len(grp),
                     "llm_weights": [g["llm_weight"] for g in grp],
                     "titles": [g["title"] for g in grp]}
                )

    summary = {
        "n": n,
        "agreement": f"{agree}/{n}",
        "agreement_pct": round(100 * agree / n, 1),
        "rule_dist": dict(Counter(r["rule_weight"] for r in rows)),
        "llm_dist": dict(Counter(r["llm_weight"] for r in rows)),
        "n_disagree": len(disagree),
        "n_high_imp_but_light_or_medium": len(high_imp_but_light),
        "n_low_imp_but_heavy": len(low_imp_but_heavy),
        "n_llm_inconsistent_dup_groups": len(inconsistent_groups),
    }

    out = {
        "summary": summary,
        "disagree": disagree,
        "counterexample_high_imp_but_light_or_medium": high_imp_but_light,
        "counterexample_low_imp_but_heavy": low_imp_but_heavy,
        "llm_inconsistent_dup_groups": inconsistent_groups,
        "all_rows": rows,
    }
    (RESULTS / "comparison.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    print("=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))

    print("\n=== 불일치 (규칙 vs LLM 무게) ===")
    print(f"{'imp':>3} {'days':>4} {'rule':7} {'llm':7} title")
    for r in sorted(disagree, key=lambda x: (WEIGHT_ORDER.get(x['rule_weight'], 9))):
        print(f"{str(r['importance']):>3} {str(r['days_until']):>4} {r['rule_weight']:7} "
              f"{str(r['llm_weight']):7} {r['title'][:42]}")

    print("\n=== 반례A: importance=5 인데 LLM 은 light/medium (heavy 과잉) ===")
    for r in high_imp_but_light:
        print(f"  d={r['days_until']:>3} {r['llm_weight']:6} {r['title'][:40]}")
        print(f"        └ {r['llm_reasoning']}")

    print("\n=== 반례B: importance<=3 인데 LLM 은 heavy (heavy 누락) ===")
    for r in low_imp_but_heavy:
        print(f"  imp={r['importance']} d={r['days_until']:>3} {r['title'][:40]}")
        print(f"        └ {r['llm_reasoning']}")

    print("\n=== LLM 안정성: 유사 중복 건에 무게가 흔들린 그룹 ===")
    for g in inconsistent_groups:
        print(f"  {g['llm_weights']}  ← {g['titles'][0][:46]}")

    print(f"\n저장: {RESULTS / 'comparison.json'}")


if __name__ == "__main__":
    main()
