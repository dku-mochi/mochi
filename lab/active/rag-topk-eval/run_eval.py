"""TOP_K 8/10/15/25 실측 — rag-rerank-eval 파이프라인 이식 (rerank-2.5 단일).

파이프라인 (프로덕션 형상):
  A  Vector → TopK                      (참고 베이스라인)
  B  Vector Top50 → rerank-2.5 → TopK   (프로덕션 검색탭 근사)
  C  Vector Top60 + BM25 Top60 → RRF Top50 → rerank-2.5 → TopK
     (채팅 search_items 형상 — RERANK_CANDIDATES=50 과 동일 폭)

지표: Recall@{8,10,15,25}, Hit@K, MRR, nDCG@25 — 전체 + tier(S/M/L)별 분해.
gold 는 data/gold_audited.json 우선(없으면 gold.json).

실행: mochi-backend 에서  set -a; source .env; set +a
  uv run --group lab python ../lab/active/rag-topk-eval/run_eval.py
"""

import argparse
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
RERANKER = "rerank-2.5"
RRF_K = 60
VEC_TOPN_B = 50
VEC_TOPN_C = 60
BM25_TOPN_C = 60
RRF_TOPN_C = 50
K_GRID = [8, 10, 15, 25]
NDCG_K = 25


def doc_text(it: dict) -> str:
    return f"{it['summary']} {' '.join(it['labels'])}".strip()


def char_bigrams(s: str) -> list[str]:
    s = "".join(s.split())
    return [s[i:i + 2] for i in range(len(s) - 1)] if len(s) >= 2 else ([s] if s else [])


class BM25:
    def __init__(self, corpus_tokens, k1=1.5, b=0.75):
        self.k1, self.b = k1, b
        self.N = len(corpus_tokens)
        self.dl = [len(d) for d in corpus_tokens]
        self.avgdl = sum(self.dl) / self.N if self.N else 0.0
        df, self.tf = defaultdict(int), []
        for d in corpus_tokens:
            tf = defaultdict(int)
            for t in d:
                tf[t] += 1
            self.tf.append(tf)
            for t in tf:
                df[t] += 1
        self.idf = {t: math.log(1 + (self.N - n + 0.5) / (n + 0.5)) for t, n in df.items()}

    def scores(self, q):
        out = np.zeros(self.N, dtype=np.float32)
        for i in range(self.N):
            tf, dl = self.tf[i], self.dl[i]
            s = 0.0
            for t in q:
                if t in tf:
                    num = tf[t] * (self.k1 + 1)
                    den = tf[t] + self.k1 * (1 - self.b + self.b * dl / self.avgdl)
                    s += self.idf.get(t, 0.0) * num / den
            out[i] = s
        return out


def recall_at_k(ranked, expected, k):
    es = set(expected)
    return sum(1 for r in ranked[:k] if r in es) / len(es) if es else 0.0


def hit_at_k(ranked, expected, k):
    es = set(expected)
    return 1.0 if any(r in es for r in ranked[:k]) else 0.0


def mrr(ranked, expected):
    es = set(expected)
    for i, r in enumerate(ranked, 1):
        if r in es:
            return 1.0 / i
    return 0.0


def ndcg_at_k(ranked, expected, k):
    es = set(expected)
    dcg = sum(1.0 / math.log2(i + 1) for i, r in enumerate(ranked[:k], 1) if r in es)
    ideal = sum(1.0 / math.log2(i + 1) for i in range(1, min(len(es), k) + 1))
    return dcg / ideal if ideal else 0.0


def rrf_fuse(*ranked_lists, k=RRF_K):
    sc = defaultdict(float)
    for rl in ranked_lists:
        for rank, rid in enumerate(rl, start=1):
            sc[rid] += 1.0 / (k + rank)
    return sorted(sc, key=lambda x: sc[x], reverse=True)


def embed_docs(vo, corpus):
    import hashlib as _h
    digest = _h.sha256("\x1e".join(doc_text(it) for it in corpus).encode()).hexdigest()[:12]
    cache = ART / f"doc_emb_{EMB_MODEL}@{DIM}_{digest}.json"
    if cache.exists():
        c = json.loads(cache.read_text(encoding="utf-8"))
        if set(c) == {it["id"] for it in corpus}:
            print(f"[cache] doc embeddings 재사용 ({len(c)})")
            return c
    print(f"[embed] {len(corpus)} docs … ({EMB_MODEL}@{DIM})")
    out, ids = {}, [it["id"] for it in corpus]
    texts = [doc_text(it) for it in corpus]
    for i in range(0, len(texts), 100):
        r = vo.embed(texts[i:i + 100], model=EMB_MODEL, input_type="document",
                     output_dimension=DIM)
        for j, vec in enumerate(r.embeddings):
            out[ids[i + j]] = vec
        print(f"  {min(i + 100, len(texts))}/{len(texts)}")
        time.sleep(0.2)
    ART.mkdir(exist_ok=True)
    cache.write_text(json.dumps(out), encoding="utf-8")
    return out


def rerank(vo, query, cand_ids, id2text):
    if not cand_ids:
        return []
    r = vo.rerank(query=query, documents=[id2text[i] for i in cand_ids],
                  model=RERANKER, top_k=len(cand_ids))
    return [cand_ids[res.index] for res in r.results]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", choices=["audited", "designed"], default="audited",
                    help="audited=독립 감사 라벨(기본) / designed=설계 라벨 — 민감도 분석")
    args = ap.parse_args()
    corpus = json.loads((DATA / "corpus.json").read_text(encoding="utf-8"))
    if args.gold == "audited":
        gold_path = DATA / "gold_audited.json"
        if not gold_path.exists():
            raise SystemExit("[ERROR] gold_audited.json 없음 — verify_qrels.py 먼저 (조용한 강등 금지)")
        meta_p = DATA / "audit_meta.json"
        if meta_p.exists():
            import hashlib as _h
            cur = _h.sha256((DATA / "corpus.json").read_bytes()).hexdigest()
            if json.loads(meta_p.read_text())["corpus_sha256"] != cur:
                raise SystemExit("[ERROR] gold_audited 가 현재 corpus 세대와 불일치 — 재감사 필요")
    else:
        gold_path = DATA / "gold.json"
    gold = json.loads(gold_path.read_text(encoding="utf-8"))
    print(f"[gold] {gold_path.name} ({len(gold)} queries) / corpus {len(corpus)}")
    vo = voyageai.Client(api_key=os.environ["VOYAGE_API_KEY"])

    ids = [it["id"] for it in corpus]
    id2text = {it["id"]: doc_text(it) for it in corpus}
    doc_emb = embed_docs(vo, corpus)
    doc_mat = np.array([doc_emb[i] for i in ids], dtype=np.float32)
    doc_mat /= (np.linalg.norm(doc_mat, axis=1, keepdims=True) + 1e-9)
    q_emb = {g["query"]: v for g, v in zip(
        gold,
        vo.embed([g["query"] for g in gold], model=EMB_MODEL, input_type="query",
                 output_dimension=DIM).embeddings, strict=True)}
    bm25 = BM25([char_bigrams(id2text[i]) for i in ids])

    per_query = []
    for g in gold:
        q, exp = g["query"], set(g["expected_ids"])
        qv = np.array(q_emb[q], dtype=np.float32)
        qv /= (np.linalg.norm(qv) or 1.0)
        vec_full = [ids[i] for i in np.argsort(doc_mat @ qv)[::-1]]
        bm_full = [ids[i] for i in np.argsort(bm25.scores(char_bigrams(q)))[::-1]]
        vec_rank = {rid: r for r, rid in enumerate(vec_full, 1)}

        cand_c = rrf_fuse(vec_full[:VEC_TOPN_C], bm_full[:BM25_TOPN_C])
        rrf_rank = {rid: r for r, rid in enumerate(cand_c, 1)}
        pipes = {
            "A": vec_full[:max(K_GRID)],
            "B": rerank(vo, q, vec_full[:VEC_TOPN_B], id2text),
            "C": rerank(vo, q, cand_c[:RRF_TOPN_C], id2text),
        }
        diag = [{
            "id": a, "vec_rank": vec_rank.get(a), "rrf_rank": rrf_rank.get(a),
            "in_vec_top50": vec_rank.get(a, 10**9) <= VEC_TOPN_B,
            "in_rrf_top50": rrf_rank.get(a, 10**9) <= RRF_TOPN_C,
            "bm25_rescued": (vec_rank.get(a, 10**9) > VEC_TOPN_C
                             and rrf_rank.get(a, 10**9) <= RRF_TOPN_C),
        } for a in sorted(exp)]
        per_query.append({"qid": g["qid"], "query": q, "tier": g["tier"],
                          "expected_ids": sorted(exp), "pipelines": pipes,
                          "answer_diag": diag})
        print(f"  [done] {g['qid']} {q}")

    # ── 집계: 파이프라인 × K × (전체/tier) ──
    def agg(rows, pipe, k):
        return round(float(np.mean([recall_at_k(r["pipelines"][pipe], r["expected_ids"], k)
                                    for r in rows])), 4)

    summary = {}
    for pipe in ("A", "B", "C"):
        summary[pipe] = {
            "recall": {f"@{k}": agg(per_query, pipe, k) for k in K_GRID},
            "hit@25": round(float(np.mean([hit_at_k(r["pipelines"][pipe], r["expected_ids"], 25)
                                           for r in per_query])), 4),
            # MRR@25 — A(25)와 B/C(50)의 평가 깊이 통일 (codex P2)
            "mrr": round(float(np.mean([mrr(r["pipelines"][pipe][:25], r["expected_ids"])
                                        for r in per_query])), 4),
            f"ndcg@{NDCG_K}": round(float(np.mean(
                [ndcg_at_k(r["pipelines"][pipe], r["expected_ids"], NDCG_K)
                 for r in per_query])), 4),
            "by_tier": {
                t: {f"@{k}": agg([r for r in per_query if r["tier"] == t], pipe, k)
                    for k in K_GRID}
                for t in ("S", "M", "L")
            },
        }
    cand = {
        "vec_top50": round(float(np.mean(
            [d["in_vec_top50"] for r in per_query for d in r["answer_diag"]])), 4),
        "rrf_top50": round(float(np.mean(
            [d["in_rrf_top50"] for r in per_query for d in r["answer_diag"]])), 4),
        "bm25_rescued": int(sum(d["bm25_rescued"] for r in per_query for d in r["answer_diag"])),
    }

    out = {"config": {"embed_model": EMB_MODEL, "dim": DIM, "reranker": RERANKER,
                      "k_grid": K_GRID, "n_corpus": len(corpus), "n_queries": len(gold),
                      "gold": gold_path.name},
           "summary": summary, "candidate_recall": cand, "per_query": per_query}
    RESULTS.mkdir(exist_ok=True)
    out_name = "eval.json" if args.gold == "audited" else "eval_designed.json"
    (RESULTS / out_name).write_text(json.dumps(out, ensure_ascii=False, indent=1),
                                       encoding="utf-8")

    print("\n" + "=" * 78)
    print(f"{'pipe':<4} " + " ".join(f"{'R@' + str(k):>8}" for k in K_GRID)
          + f" {'MRR':>7} {'nDCG@25':>8}")
    for pipe in ("A", "B", "C"):
        s = summary[pipe]
        print(f"{pipe:<4} " + " ".join(f"{s['recall'][f'@{k}']:>8.4f}" for k in K_GRID)
              + f" {s['mrr']:>7.4f} {s[f'ndcg@{NDCG_K}']:>8.4f}")
    print("-" * 78)
    for t in ("S", "M", "L"):
        s = summary["C"]["by_tier"][t]
        print(f"C/{t:<2} " + " ".join(f"{s[f'@{k}']:>8.4f}" for k in K_GRID))
    print(f"후보 recall: vec_top50={cand['vec_top50']}  rrf_top50={cand['rrf_top50']}"
          f"  bm25_rescue={cand['bm25_rescued']}")
    print(f"저장: {RESULTS / out_name}")


if __name__ == "__main__":
    main()
