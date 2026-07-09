#!/usr/bin/env python3
"""골든 eval 스냅샷 통계 — Wilson 95% CI 리포트.

run_golden.py 가 남긴 스냅샷(_summary.json)을 읽어 스위트별로:
- 케이스 수준: strict pass(케이스의 모든 run 통과) 비율 + Wilson 95% CI
- run 수준: 통과 run 비율 + Wilson 95% CI (참고용 — 같은 케이스의 run 은 독립이 아니므로
  보수적 주장은 케이스 수준 CI 를 쓴다)
- 축 수준(core 채점 스위트): recall / date 정확도 / type 정확도 / 과생성·노이즈 발생 run 비율

사용: python eval/stats.py eval/snapshots/v28_full_clear [eval/snapshots/...]
순수 stdlib — LLM/네트워크 없음.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

Z = 1.959964  # 95%


def wilson(k: int, n: int) -> tuple[float, float, float]:
    """(비율, CI 하한, CI 상한). n=0 이면 (nan, nan, nan)."""
    if n == 0:
        return (float("nan"),) * 3
    p = k / n
    denom = 1 + Z * Z / n
    center = (p + Z * Z / (2 * n)) / denom
    half = Z * math.sqrt(p * (1 - p) / n + Z * Z / (4 * n * n)) / denom
    return p, max(0.0, center - half), min(1.0, center + half)


def fmt(k: int, n: int) -> str:
    p, lo, hi = wilson(k, n)
    if math.isnan(p):
        return "—"
    return f"{k}/{n} = {p * 100:.1f}% (95% CI {lo * 100:.1f}–{hi * 100:.1f}%)"


def suite_stats(summary_path: Path) -> dict:
    j = json.loads(summary_path.read_text())
    results = j["results"]
    scored = [r for r in results if r.get("pass_rate") is not None]

    strict = sum(1 for r in scored if r["pass_rate"] == 1.0)
    runs_total = runs_pass = 0
    core_total = core_hit = 0
    date_total = date_ok = 0
    type_total = type_ok = 0
    over_runs = noise_runs = axis_runs = 0

    for r in scored:
        for run in r["runs"]:
            s = run.get("score")
            if not s:
                runs_total += 1  # 에러 run 은 실패로 집계
                continue
            runs_total += 1
            if s.get("passed"):
                runs_pass += 1
            rd = s.get("recall_detail")
            if rd:
                axis_runs += 1
                core_total += len(rd)
                core_hit += sum(1 for v in rd.values() if v)
            dc = s.get("date_check")
            if dc:
                date_total += len(dc)
                date_ok += sum(1 for v in dc.values() if v[1])
            if "type_ok" in s:
                type_total += 1
                type_ok += 1 if s["type_ok"] else 0
            if s.get("over"):
                over_runs += 1
            if s.get("noise"):
                noise_runs += 1

    return {
        "name": summary_path.parent.name,
        "model": j["model"],
        "prompt": j["base_prompt"],
        "n_cases": len(scored),
        "runs_per_case": j["runs_per_case"],
        "strict": (strict, len(scored)),
        "runs": (runs_pass, runs_total),
        "mean_case_pass": sum(r["pass_rate"] for r in scored) / len(scored) if scored else float("nan"),
        "core": (core_hit, core_total),
        "date": (date_ok, date_total),
        "type": (type_ok, type_total),
        "over_runs": (over_runs, axis_runs),
    }


def main() -> int:
    dirs = [Path(a) for a in sys.argv[1:]]
    if not dirs:
        print("usage: python eval/stats.py <snapshot_dir> [...]", file=sys.stderr)
        return 2
    grand_strict = [0, 0]
    grand_runs = [0, 0]
    for d in dirs:
        st = suite_stats(d / "_summary.json")
        print(
            f"\n## {st['name']}  (model={st['model']}, prompt={st['prompt']}, "
            f"n={st['n_cases']} cases x {st['runs_per_case']} runs)"
        )
        print(f"  케이스 strict(3/3) : {fmt(*st['strict'])}")
        print(f"  run 수준           : {fmt(*st['runs'])}")
        print(f"  케이스 mean pass   : {st['mean_case_pass'] * 100:.1f}%")
        if st["core"][1]:
            print(f"  core 항목 회수     : {fmt(*st['core'])}")
        if st["date"][1]:
            print(f"  날짜 정확도        : {fmt(*st['date'])}")
        if st["type"][1]:
            print(f"  type 정확도(run)   : {fmt(*st['type'])}")
        if st["over_runs"][1]:
            k, n = st["over_runs"]
            print(f"  과생성 발생 run    : {k}/{n}")
        grand_strict[0] += st["strict"][0]
        grand_strict[1] += st["strict"][1]
        grand_runs[0] += st["runs"][0]
        grand_runs[1] += st["runs"][1]
    if len(dirs) > 1:
        print(f"\n## 전체 (suites={len(dirs)})")
        print(f"  케이스 strict      : {fmt(*grand_strict)}")
        print(f"  run 수준           : {fmt(*grand_runs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
