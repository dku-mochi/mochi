"""6개 카테고리 코퍼스 청크를 병합하고 gold 쿼리를 자동 구성한다.

입력:  data/corpus_*.json  (각 item: id, summary, labels, entities, category, role, for_query)
출력:  data/corpus.json    (병합 코퍼스 — role/for_query 메타 포함, 평가 시 summary+labels만 임베딩)
       data/gold.json      (쿼리별 expected_ids — role==answer 인 항목만 정답)

정합성 검증:
  · id 전역 유일
  · 모든 expected_id 가 코퍼스에 존재
  · 각 쿼리 정답 수 / hard_neg 수 출력
"""

import json
from collections import defaultdict
from pathlib import Path

DATA = Path(__file__).parent / "data"
CHUNKS = sorted(DATA.glob("corpus_*.json"))


def main() -> None:
    corpus: list[dict] = []
    seen_ids: set[str] = set()
    dupes: list[str] = []

    for ch in CHUNKS:
        items = json.loads(ch.read_text(encoding="utf-8"))
        for it in items:
            if it["id"] in seen_ids:
                dupes.append(it["id"])
            seen_ids.add(it["id"])
        corpus.extend(items)
        print(f"  {ch.name:28s} {len(items):3d} items")

    print(f"\n총 {len(corpus)} items, 고유 id {len(seen_ids)}개")
    if dupes:
        print(f"[ERROR] 중복 id: {dupes}")
        return

    # ── gold 구성: role==answer 를 for_query 로 묶음 ──
    answers: dict[str, list[str]] = defaultdict(list)
    hardneg: dict[str, list[str]] = defaultdict(list)
    for it in corpus:
        if it["role"] == "answer":
            answers[it["for_query"]].append(it["id"])
        elif it["role"] == "hard_neg":
            hardneg[it["for_query"]].append(it["id"])

    gold = []
    id_set = {it["id"] for it in corpus}
    for q in sorted(answers):
        exp = sorted(answers[q])
        missing = [i for i in exp if i not in id_set]
        if missing:
            print(f"[ERROR] '{q}' expected_id 누락: {missing}")
            return
        gold.append({
            "query": q,
            "expected_ids": exp,
            "single_answer": len(exp) == 1,   # True 면 Hit@10 도 의미
            "n_hard_neg": len(hardneg.get(q, [])),
        })

    # ── 저장 ──
    (DATA / "corpus.json").write_text(
        json.dumps(corpus, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (DATA / "gold.json").write_text(
        json.dumps(gold, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # ── 요약 ──
    n_ans = sum(1 for it in corpus if it["role"] == "answer")
    n_hn = sum(1 for it in corpus if it["role"] == "hard_neg")
    n_fill = sum(1 for it in corpus if it["role"] == "filler")
    print(f"\nrole 분포: answer={n_ans}  hard_neg={n_hn}  filler={n_fill}")
    print(f"gold 쿼리 {len(gold)}개\n")
    print(f"{'쿼리':<14} {'정답수':>5} {'hard_neg':>9} {'유형':>8}")
    print("-" * 42)
    for g in gold:
        kind = "Hit@10" if g["single_answer"] else "Recall@10"
        print(f"{g['query']:<14} {len(g['expected_ids']):>5} {g['n_hard_neg']:>9} {kind:>10}")

    print(f"\n저장: data/corpus.json ({len(corpus)}), data/gold.json ({len(gold)})")


if __name__ == "__main__":
    main()
