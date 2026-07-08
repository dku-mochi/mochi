"""검색 파이프라인 A/B/C 비교 — voyage-4-large 임베딩 + voyage reranker.

파이프라인:
  A  Vector → Top10
  B  Vector Top50 → Reranker → Top10
  C  Vector Top60 + BM25 Top60 → RRF Top50 → Reranker → Top10
     (RRF 는 recall 단계 통합용, 최종 순위는 reranker 점수)

임베딩:  voyage-4-large @ 1024,  doc/query input = summary + labels (input_type 구분)
Reranker: rerank-2.5, rerank-2.5-lite 비교
BM25:    char bi-gram 토크나이저 (한국어 조사 영향 최소화)
RRF k:   60

지표:  Recall@10 (전체), Hit@10 (단일정답 쿼리)
       + 후보단계 진단 (정답별 vec_rank / bm25_rank / rrf_rank / final_rank)

실행 (mochi-backend 디렉토리에서, VOYAGE_API_KEY 필요):
  set -a; source .env; set +a
  uv run --group lab python ../lab/active/rag-rerank-eval/run_eval.py
"""

import json
import math
import os
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import voyageai

ROOT = Path(__file__).parent
DATA = ROOT / "data"
ART = ROOT / "artifacts"
RESULTS = ROOT / "results"

EMB_MODEL = "voyage-4-large"
DIM = 1024
RERANKERS = ["rerank-2.5", "rerank-2.5-lite"]
RRF_K = 60

VEC_TOPN_B = 50          # B: vector 후보
VEC_TOPN_C = 60          # C: vector 후보
BM25_TOPN_C = 60         # C: bm25 후보
RRF_TOPN_C = 50          # C: rrf 통합 후 reranker 입력
FINAL_K = 10


# ── 텍스트 / 토크나이저 ────────────────────────────────────────────────────────

def doc_text(it: dict) -> str:
    """임베딩·reranker 입력 = summary + labels (사용자 결정)."""
    return f"{it['summary']} {' '.join(it['labels'])}".strip()


def char_bigrams(s: str) -> list[str]:
    s = "".join(s.split())
    if len(s) < 2:
        return [s] if s else []
    return [s[i:i + 2] for i in range(len(s) - 1)]


# ── BM25 (char bi-gram) ────────────────────────────────────────────────────────

class BM25:
    def __init__(self, corpus_tokens: list[list[str]], k1=1.5, b=0.75):
        self.k1, self.b = k1, b
        self.docs = corpus_tokens
        self.N = len(corpus_tokens)
        self.dl = [len(d) for d in corpus_tokens]
        self.avgdl = sum(self.dl) / self.N if self.N else 0.0
        df: dict[str, int] = defaultdict(int)
        self.tf: list[dict[str, int]] = []
        for d in corpus_tokens:
            tf: dict[str, int] = defaultdict(int)
            for t in d:
                tf[t] += 1
            self.tf.append(tf)
            for t in tf:
                df[t] += 1
        self.idf = {
            t: math.log(1 + (self.N - n + 0.5) / (n + 0.5)) for t, n in df.items()
        }

    def scores(self, query_tokens: list[str]) -> np.ndarray:
        out = np.zeros(self.N, dtype=np.float32)
        for i in range(self.N):
            tf, dl = self.tf[i], self.dl[i]
            s = 0.0
            for t in query_tokens:
                if t not in tf:
                    continue
                idf = self.idf.get(t, 0.0)
                num = tf[t] * (self.k1 + 1)
                den = tf[t] + self.k1 * (1 - self.b + self.b * dl / self.avgdl)
                s += idf * num / den
            out[i] = s
        return out


# ── 지표 ──────────────────────────────────────────────────────────────────────

def recall_at_k(ranked: list[str], expected: list[str], k: int) -> float:
    es = set(expected)
    return sum(1 for r in ranked[:k] if r in es) / len(es) if es else 0.0


def hit_at_k(ranked: list[str], expected: list[str], k: int) -> float:
    es = set(expected)
    return 1.0 if any(r in es for r in ranked[:k]) else 0.0


# ── RRF ───────────────────────────────────────────────────────────────────────

def rrf_fuse(*ranked_lists: list[str], k: int = RRF_K) -> list[str]:
    sc: dict[str, float] = defaultdict(float)
    for rl in ranked_lists:
        for rank, rid in enumerate(rl, start=1):
            sc[rid] += 1.0 / (k + rank)
    return sorted(sc, key=lambda x: sc[x], reverse=True)


# ── 임베딩 (캐시) ──────────────────────────────────────────────────────────────

def embed_docs(vo: voyageai.Client, corpus: list[dict]) -> dict[str, list[float]]:
    cache_path = ART / f"doc_emb_{EMB_MODEL}@{DIM}.json"
    if cache_path.exists():
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        if set(cached) == {it["id"] for it in corpus}:
            print(f"[cache] doc embeddings 재사용 ({len(cached)})")
            return cached
    print(f"[embed] {len(corpus)} docs … ({EMB_MODEL}@{DIM})")
    out: dict[str, list[float]] = {}
    ids = [it["id"] for it in corpus]
    texts = [doc_text(it) for it in corpus]
    B = 100
    for i in range(0, len(texts), B):
        chunk = texts[i:i + B]
        r = vo.embed(chunk, model=EMB_MODEL, input_type="document", output_dimension=DIM)
        for j, vec in enumerate(r.embeddings):
            out[ids[i + j]] = vec
        print(f"  {min(i + B, len(texts))}/{len(texts)}")
        time.sleep(0.2)
    ART.mkdir(exist_ok=True)
    cache_path.write_text(json.dumps(out), encoding="utf-8")
    return out


def embed_queries(vo: voyageai.Client, queries: list[str]) -> dict[str, list[float]]:
    r = vo.embed(queries, model=EMB_MODEL, input_type="query", output_dimension=DIM)
    return {q: vec for q, vec in zip(queries, r.embeddings, strict=True)}


def cosine_rank(qvec: list[float], doc_mat: np.ndarray, ids: list[str]) -> list[str]:
    q = np.array(qvec, dtype=np.float32)
    q /= (np.linalg.norm(q) or 1.0)
    sims = doc_mat @ q
    order = np.argsort(sims)[::-1]
    return [ids[i] for i in order]


# ── reranker ──────────────────────────────────────────────────────────────────

def rerank(vo: voyageai.Client, model: str, query: str,
           cand_ids: list[str], id2text: dict[str, str]) -> list[str]:
    if not cand_ids:
        return []
    docs = [id2text[i] for i in cand_ids]
    r = vo.rerank(query=query, documents=docs, model=model, top_k=len(cand_ids))
    return [cand_ids[res.index] for res in r.results]


# ── 메인 ──────────────────────────────────────────────────────────────────────

def main() -> None:
    corpus = json.loads((DATA / "corpus.json").read_text(encoding="utf-8"))
    gold = json.loads((DATA / "gold.json").read_text(encoding="utf-8"))
    vo = voyageai.Client(api_key=os.environ["VOYAGE_API_KEY"])

    ids = [it["id"] for it in corpus]
    id2text = {it["id"]: doc_text(it) for it in corpus}
    id2item = {it["id"]: it for it in corpus}

    # 임베딩
    doc_emb = embed_docs(vo, corpus)
    doc_mat = np.array([doc_emb[i] for i in ids], dtype=np.float32)
    doc_mat /= (np.linalg.norm(doc_mat, axis=1, keepdims=True) + 1e-9)
    q_emb = embed_queries(vo, [g["query"] for g in gold])

    # BM25
    bm25 = BM25([char_bigrams(t) for t in (id2text[i] for i in ids)])

    # ── 쿼리별 전 단계 랭킹 + 진단 ──
    per_query = []
    for g in gold:
        q = g["query"]
        exp = set(g["expected_ids"])

        vec_full = cosine_rank(q_emb[q], doc_mat, ids)
        bm_scores = bm25.scores(char_bigrams(q))
        bm_full = [ids[i] for i in np.argsort(bm_scores)[::-1]]

        vec_rank = {rid: r for r, rid in enumerate(vec_full, 1)}
        bm_rank = {rid: r for r, rid in enumerate(bm_full, 1)}

        # C 후보 통합
        cand_c = rrf_fuse(vec_full[:VEC_TOPN_C], bm_full[:BM25_TOPN_C])
        rrf_full_rank = {rid: r for r, rid in enumerate(cand_c, 1)}
        rrf_top = cand_c[:RRF_TOPN_C]

        # B 후보
        cand_b = vec_full[:VEC_TOPN_B]

        # 파이프라인 A
        a_top = vec_full[:FINAL_K]

        # 파이프라인 B/C × reranker
        ranks = {"A": {None: a_top}, "B": {}, "C": {}}
        for m in RERANKERS:
            ranks["B"][m] = rerank(vo, m, q, cand_b, id2text)[:FINAL_K]
            ranks["C"][m] = rerank(vo, m, q, rrf_top, id2text)[:FINAL_K]

        # 정답별 진단
        ans_diag = []
        for aid in sorted(exp):
            ans_diag.append({
                "id": aid,
                "vec_rank": vec_rank.get(aid),
                "bm25_rank": bm_rank.get(aid),
                "in_vec_top50": vec_rank.get(aid, 10**9) <= VEC_TOPN_B,
                "in_vec_top60": vec_rank.get(aid, 10**9) <= VEC_TOPN_C,
                "rrf_rank": rrf_full_rank.get(aid),
                "in_rrf_top50": rrf_full_rank.get(aid, 10**9) <= RRF_TOPN_C,
                # BM25 가 vector 가 못 올린 정답을 RRF 후보에 넣었나
                "bm25_rescued": (vec_rank.get(aid, 10**9) > VEC_TOPN_C
                                 and rrf_full_rank.get(aid, 10**9) <= RRF_TOPN_C),
                "final_rank": {
                    "A": (a_top.index(aid) + 1) if aid in a_top else None,
                    **{f"B/{m}": (ranks["B"][m].index(aid) + 1) if aid in ranks["B"][m] else None
                       for m in RERANKERS},
                    **{f"C/{m}": (ranks["C"][m].index(aid) + 1) if aid in ranks["C"][m] else None
                       for m in RERANKERS},
                },
            })

        per_query.append({
            "query": q,
            "expected_ids": sorted(exp),
            "single_answer": g["single_answer"],
            "pipelines": {
                "A": a_top,
                **{f"B/{m}": ranks["B"][m] for m in RERANKERS},
                **{f"C/{m}": ranks["C"][m] for m in RERANKERS},
            },
            "answer_diag": ans_diag,
            "vec_top10": vec_full[:10],
            "bm25_top10": bm_full[:10],
        })
        print(f"  [done] {q}")

    # ── 집계 ──
    labels = ["A"] + [f"B/{m}" for m in RERANKERS] + [f"C/{m}" for m in RERANKERS]
    agg = {lab: {"recall@10": [], "hit@10": []} for lab in labels}
    for pq in per_query:
        exp = pq["expected_ids"]
        for lab in labels:
            ranked = pq["pipelines"][lab]
            agg[lab]["recall@10"].append(recall_at_k(ranked, exp, FINAL_K))
            agg[lab]["hit@10"].append(hit_at_k(ranked, exp, FINAL_K))
    summary = {
        lab: {
            "recall@10": round(float(np.mean(v["recall@10"])), 4),
            "hit@10": round(float(np.mean(v["hit@10"])), 4),
        } for lab, v in agg.items()
    }

    # 후보단계 recall (정답이 vec_top50 / rrf_top50 에 든 비율)
    cand_recall = {"vec_top50": [], "rrf_top50": []}
    for pq in per_query:
        for d in pq["answer_diag"]:
            cand_recall["vec_top50"].append(1.0 if d["in_vec_top50"] else 0.0)
            cand_recall["rrf_top50"].append(1.0 if d["in_rrf_top50"] else 0.0)
    cand_recall_summary = {
        k: round(float(np.mean(v)), 4) for k, v in cand_recall.items()
    }

    out = {
        "config": {
            "embed_model": EMB_MODEL, "dim": DIM, "doc_input": "summary+labels",
            "rerankers": RERANKERS, "rrf_k": RRF_K,
            "vec_topn_B": VEC_TOPN_B, "vec_topn_C": VEC_TOPN_C,
            "bm25_topn_C": BM25_TOPN_C, "rrf_topn_C": RRF_TOPN_C,
            "n_corpus": len(corpus), "n_queries": len(gold),
        },
        "summary": summary,
        "candidate_recall": cand_recall_summary,
        "per_query": per_query,
    }
    RESULTS.mkdir(exist_ok=True)
    out_path = RESULTS / "eval.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    # ── 콘솔 요약 ──
    print("\n" + "=" * 70)
    print(f"{'파이프라인':<18} {'Recall@10':>12} {'Hit@10':>10}")
    print("-" * 70)
    for lab in labels:
        s = summary[lab]
        print(f"{lab:<18} {s['recall@10']:>12.4f} {s['hit@10']:>10.4f}")
    print("-" * 70)
    print(f"{'후보 recall':<18} vec_top50={cand_recall_summary['vec_top50']:.4f}  "
          f"rrf_top50={cand_recall_summary['rrf_top50']:.4f}")
    print(f"\n저장: {out_path}")


if __name__ == "__main__":
    main()
