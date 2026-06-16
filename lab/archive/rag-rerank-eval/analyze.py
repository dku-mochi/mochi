"""eval.json 재분석 — 추가 API 호출 없이.

@10 천장 효과를 진단하기 위해 더 엄격한 k(@1/@3/@5)와 MRR 로 재집계하고,
사용자 요청 5개 분석 사례를 per_query 데이터에서 추출한다.
"""

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).parent
RES = json.loads((ROOT / "results" / "eval.json").read_text(encoding="utf-8"))
PQ = RES["per_query"]
RERANKERS = RES["config"]["rerankers"]
LABELS = ["A"] + [f"B/{m}" for m in RERANKERS] + [f"C/{m}" for m in RERANKERS]


def recall_k(ranked, exp, k):
    es = set(exp)
    return sum(1 for r in ranked[:k] if r in es) / len(es) if es else 0.0


def mrr(ranked, exp):
    es = set(exp)
    for i, r in enumerate(ranked, 1):
        if r in es:
            return 1.0 / i
    return 0.0


# ── 1. 엄격 지표 재집계 ──
print("=" * 78)
print("엄격 지표 재집계 (전 쿼리 평균)")
print(f"{'파이프라인':<18} {'R@1':>7} {'R@3':>7} {'R@5':>7} {'R@10':>7} {'MRR':>7}")
print("-" * 78)
for lab in LABELS:
    r1 = np.mean([recall_k(pq["pipelines"][lab], pq["expected_ids"], 1) for pq in PQ])
    r3 = np.mean([recall_k(pq["pipelines"][lab], pq["expected_ids"], 3) for pq in PQ])
    r5 = np.mean([recall_k(pq["pipelines"][lab], pq["expected_ids"], 5) for pq in PQ])
    r10 = np.mean([recall_k(pq["pipelines"][lab], pq["expected_ids"], 10) for pq in PQ])
    mr = np.mean([mrr(pq["pipelines"][lab], pq["expected_ids"]) for pq in PQ])
    print(f"{lab:<18} {r1:>7.4f} {r3:>7.4f} {r5:>7.4f} {r10:>7.4f} {mr:>7.4f}")

# ── 2. 후보단계 진단 ──
print("\n" + "=" * 78)
print("후보단계 진단")
n_ans = sum(len(pq["answer_diag"]) for pq in PQ)
vec50 = sum(1 for pq in PQ for d in pq["answer_diag"] if d["in_vec_top50"])
rrf50 = sum(1 for pq in PQ for d in pq["answer_diag"] if d["in_rrf_top50"])
rescued = [(pq["query"], d["id"], d["vec_rank"], d["rrf_rank"])
           for pq in PQ for d in pq["answer_diag"] if d["bm25_rescued"]]
print(f"정답 총 {n_ans}개")
print(f"  vec_top50 포함: {vec50}/{n_ans}  ({vec50/n_ans:.1%})")
print(f"  rrf_top50 포함: {rrf50}/{n_ans}  ({rrf50/n_ans:.1%})")
print(f"  BM25 rescue (vec_top60 밖→rrf_top50 진입): {len(rescued)}건")
for q, aid, vr, rr in rescued:
    print(f"    · '{q}' {aid}: vec_rank={vr} → rrf_rank={rr}")

# ── 3. 사용자 요청 5개 분석 사례 ──
print("\n" + "=" * 78)
print("[분석 1] Vector 단독(A) → Vector+Reranker(B) 개선 사례")
for pq in PQ:
    exp = set(pq["expected_ids"])
    a_hits = [r for r in pq["pipelines"]["A"][:10] if r in exp]
    for m in RERANKERS:
        b_hits = [r for r in pq["pipelines"][f"B/{m}"][:10] if r in exp]
        # 정답 순위가 올라간 경우
        for d in pq["answer_diag"]:
            fa = d["final_rank"]["A"]
            fb = d["final_rank"][f"B/{m}"]
            if fa and fb and fb < fa:
                print(f"  '{pq['query']}' {d['id']}: A순위 {fa} → B/{m} {fb} (상승)")
            elif fa is None and fb is not None:
                print(f"  '{pq['query']}' {d['id']}: A에서 top10 밖 → B/{m} {fb}위 진입 ✅")

print("\n[분석 2] Vector+Reranker(B) → Hybrid+Reranker(C) 개선 사례")
found2 = False
for pq in PQ:
    for m in RERANKERS:
        for d in pq["answer_diag"]:
            fb = d["final_rank"][f"B/{m}"]
            fc = d["final_rank"][f"C/{m}"]
            if (fb is None and fc is not None):
                print(f"  '{pq['query']}' {d['id']}: B/{m} top10 밖 → C/{m} {fc}위 진입 ✅")
                found2 = True
            elif fb and fc and fc < fb:
                print(f"  '{pq['query']}' {d['id']}: B/{m} {fb} → C/{m} {fc} (상승)")
                found2 = True
if not found2:
    print("  (B 대비 C 가 정답을 추가로 올린 사례 없음)")

print("\n[분석 3] BM25가 Vector에서 누락된 정답을 추가한 사례")
if rescued:
    for q, aid, vr, rr in rescued:
        print(f"  '{q}' {aid}: vector {vr}위(top60 밖) → BM25 결합 후 RRF {rr}위로 후보 진입")
else:
    print("  없음 — vector top60이 이미 모든 정답을 포함(천장). BM25 보강 불필요.")

print("\n[분석 4] BM25가 추가한 노이즈를 reranker가 제거한 사례")
found4 = False
for pq in PQ:
    exp = set(pq["expected_ids"])
    # BM25 top10 중 비정답(노이즈)이 C 후보엔 들어왔지만 최종 top10에선 빠진 것
    bm_noise = [r for r in pq["bm25_top10"] if r not in exp]
    for m in RERANKERS:
        c_final = set(pq["pipelines"][f"C/{m}"][:10])
        removed = [r for r in bm_noise if r not in c_final]
        if removed and len(removed) >= 3:
            print(f"  '{pq['query']}' (C/{m}): BM25 상위 노이즈 {len(removed)}건이 최종 top10에서 제거됨 "
                  f"(예: {removed[:3]})")
            found4 = True
            break
if not found4:
    print("  (뚜렷한 사례 추출 안 됨 — 상세는 per_query 참조)")

print("\n[분석 5] RRF 후보엔 있었으나 reranker가 top10 밖으로 민 정답")
found5 = False
for pq in PQ:
    for m in RERANKERS:
        for d in pq["answer_diag"]:
            if d["in_rrf_top50"] and d["final_rank"][f"C/{m}"] is None:
                print(f"  '{pq['query']}' {d['id']}: RRF후보 {d['rrf_rank']}위 → C/{m} reranker가 top10 밖으로 탈락 ❌")
                found5 = True
if not found5:
    print("  없음 — reranker가 후보 내 정답을 모두 top10에 유지.")
