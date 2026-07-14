"""샤드 병합 + 결정적 Veracity 1차(스키마·중복) + 4V 통계.

입력:  data/shards/*.json
출력:  data/corpus.json  data/gold.json  data/stats.json

검증(결정적):
  · id 전역 유일 / role 수가 config 스펙과 일치
  · 근사중복 스캔(char-bigram jaccard ≥ 0.70) — 의도 주입 dup(dup_of)은 기대 목록,
    그 밖의 교차 중복은 unexpected 로 보고(경고만 — 판단은 FINDINGS 에)
  · gold: answer(+answer dup)만 expected_ids
"""

import json
import sys
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import FILLER_SPECS, QUERY_SPECS  # noqa: E402

ROOT = Path(__file__).parent
DATA = ROOT / "data"
SHARDS = DATA / "shards"


def bigrams(s: str) -> set[str]:
    s = "".join(s.split())
    return {s[i:i + 2] for i in range(len(s) - 1)}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def main() -> None:
    spec_by_id = {(s.get("qid") or s["bid"]): s for s in QUERY_SPECS + FILLER_SPECS}
    shards = sorted(SHARDS.glob("*.json"))
    missing = set(spec_by_id) - {p.stem for p in shards}
    if missing:
        print(f"[ERROR] 샤드 누락: {sorted(missing)} — gen_corpus.py 먼저")
        return

    corpus: list[dict] = []
    for p in shards:
        items = json.loads(p.read_text(encoding="utf-8"))
        spec = spec_by_id[p.stem]
        roles = Counter(it["role"] for it in items)
        for it in items:  # stale shard 가드 — config 변경 후 잔존 샤드 검출
            assert it["persona"] == spec["persona"], f"{p.stem}: persona 불일치"
            assert it["for_query"] == spec.get("query"), f"{p.stem}: for_query 불일치"
            assert it["tier"] == spec.get("tier"), f"{p.stem}: tier 불일치"
        if "query" not in spec:
            assert len(items) == spec["n"], f"{p.stem}: filler 수 {len(items)}/{spec['n']}"
        if "query" in spec:
            want_ans = spec["n_answer"] + (1 if spec["dup"] else 0)
            assert roles["answer"] == want_ans and roles["hard_neg"] == spec["n_hard_neg"], \
                f"{p.stem}: role 불일치 {dict(roles)}"
        corpus.extend(items)

    ids = [it["id"] for it in corpus]
    assert len(ids) == len(set(ids)), "id 중복"

    # ── 근사중복 스캔 (answer/hard_neg 만 — filler 교차는 노이즈로 허용) ──
    keyed = [(it["id"], bigrams(it["summary"]), it) for it in corpus if it["role"] != "filler"]
    expected_pairs = {(it["dup_of"], it["id"]) for it in corpus if it.get("dup_of")}
    unexpected = []
    for (ia, ba, ita), (ib, bb, itb) in combinations(keyed, 2):
        j = jaccard(ba, bb)
        if j >= 0.70 and (ia, ib) not in expected_pairs and (ib, ia) not in expected_pairs:
            unexpected.append({"a": ia, "b": ib, "jaccard": round(j, 3),
                               "cross_query": ita["for_query"] != itb["for_query"]})

    # ── gold ──
    answers: dict[str, list[str]] = defaultdict(list)
    for it in corpus:
        if it["role"] == "answer" and it["for_query"]:
            answers[it["for_query"]].append(it["id"])
    gold = []
    for s in QUERY_SPECS:
        exp = sorted(answers[s["query"]])
        gold.append({
            "query": s["query"], "qid": s["qid"], "tier": s["tier"],
            "expected_ids": exp, "single_answer": len(exp) == 1,
            "n_hard_neg": s["n_hard_neg"],
        })

    # ── 4V 통계 ──
    month_hist = Counter(it["captured_at"][:7] for it in corpus)
    stats = {
        "volume": {
            "n_items": len(corpus),
            "roles": dict(Counter(it["role"] for it in corpus)),
            "n_queries": len(gold),
            "answers_per_tier": {
                t: sorted(len(g["expected_ids"]) for g in gold if g["tier"] == t)
                for t in ("S", "M", "L")
            },
        },
        "variety": {
            "persona": dict(Counter(it["persona"] for it in corpus)),
            "type": dict(Counter(it["type"] for it in corpus)),
            "domain": dict(Counter(it["category"] for it in corpus)),
        },
        "velocity": {
            "captured_month_hist": dict(sorted(month_hist.items())),
            "n_dup_resaves": sum(1 for it in corpus if it.get("dup_of")),
            "n_with_occurs": sum(1 for it in corpus if it.get("occurs")),
        },
        "veracity_deterministic": {
            "unexpected_near_dups": unexpected,
            "n_unexpected_near_dups": len(unexpected),
        },
    }

    (DATA / "corpus.json").write_text(json.dumps(corpus, ensure_ascii=False, indent=1), encoding="utf-8")
    (DATA / "gold.json").write_text(json.dumps(gold, ensure_ascii=False, indent=1), encoding="utf-8")
    (DATA / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"코퍼스 {len(corpus)} items / 쿼리 {len(gold)}")
    print(json.dumps(stats["volume"], ensure_ascii=False, indent=1))
    print("월별 분포:", dict(sorted(month_hist.items())))
    print(f"unexpected near-dup: {len(unexpected)}")
    if unexpected[:5]:
        print(json.dumps(unexpected[:5], ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
