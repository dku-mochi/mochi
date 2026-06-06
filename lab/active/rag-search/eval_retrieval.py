"""3단계: 임베딩 벡터 + gold 쿼리 → 검색 품질 평가.

평가 방식:
  · BM25 단독 (rank-bm25 — 없으면 즉시 실패)
  · Vector 단독 (각 embed combo)
  · BM25 + Vector + RRF (k=60)

평가 지표:
  · HitRate@3, Recall@5, MRR, nDCG@5
  · 쿼리 유형별 (type) 분리 집계

실행 (mochi-backend 디렉토리에서):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \\
  GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \\
  uv run --group lab python "../lab/active/rag-search/eval_retrieval.py" [--analysis-fp <fp>] [--allow-partial]

결과: results/retrieval/YYYYMMDD_HHMMSS.json
"""

import argparse
import asyncio
import json
import math
import os
import sys
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np
from google import genai
from google.genai import types

try:
    from rank_bm25 import BM25Okapi
except ImportError as exc:
    raise RuntimeError(
        "rank-bm25 required. install: uv add --group lab rank-bm25"
    ) from exc

sys.path.insert(0, str(Path(__file__).parent))
from _lab_utils import analysis_hash as _analysis_hash  # noqa: E402, I001
from _lab_utils import expected_embed_names  # noqa: E402, I001

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
EMBED_DIR = LAB_ROOT / "artifacts" / "embeddings"
GOLD_PATH = LAB_ROOT / "gold" / "queries.json"
RESULTS_DIR = LAB_ROOT / "results" / "retrieval"

RRF_K = 60


# ── 지표 ──────────────────────────────────────────────────────────────────────

def _hit_rate_at_k(ranked: list[str], expected: list[str], k: int) -> float:
    return 1.0 if any(r in set(expected) for r in ranked[:k]) else 0.0


def _recall_at_k(ranked: list[str], expected: list[str], k: int) -> float:
    hits = sum(1 for r in ranked[:k] if r in set(expected))
    return hits / len(expected) if expected else 0.0


def _mrr(ranked: list[str], expected: list[str]) -> float:
    for rank, rid in enumerate(ranked, start=1):
        if rid in set(expected):
            return 1.0 / rank
    return 0.0


def _ndcg_at_k(ranked: list[str], expected: list[str], k: int = 5) -> float:
    expected_set = set(expected)
    dcg = sum(
        1.0 / math.log2(r + 1)
        for r, rid in enumerate(ranked[:k], start=1)
        if rid in expected_set
    )
    ideal = sum(1.0 / math.log2(r + 1) for r in range(1, min(len(expected), k) + 1))
    return dcg / ideal if ideal > 0 else 0.0


def _metrics(ranked: list[str], expected: list[str]) -> dict:
    return {
        "hit_rate@3": round(_hit_rate_at_k(ranked, expected, 3), 3),
        "recall@5": round(_recall_at_k(ranked, expected, 5), 3),
        "mrr": round(_mrr(ranked, expected), 3),
        "ndcg@5": round(_ndcg_at_k(ranked, expected, 5), 3),
    }


def _avg_metrics(query_results: list[dict]) -> dict:
    keys = ["hit_rate@3", "recall@5", "mrr", "ndcg@5"]
    n = len(query_results)
    return {k: round(sum(r[k] for r in query_results) / n, 3) for k in keys}


# ── BM25 ──────────────────────────────────────────────────────────────────────

def _bm25_rank(corpus: list[str], query: str) -> list[int]:
    tokenized = [doc.split() for doc in corpus]
    bm25 = BM25Okapi(tokenized)
    scores = bm25.get_scores(query.split())
    return list(np.argsort(scores)[::-1])


# ── RRF ───────────────────────────────────────────────────────────────────────

def _rrf_fuse(*ranked_lists: list[str], k: int = RRF_K) -> list[str]:
    scores: dict[str, float] = defaultdict(float)
    for ranked in ranked_lists:
        for rank, item_id in enumerate(ranked, start=1):
            scores[item_id] += 1.0 / (k + rank)
    return sorted(scores, key=lambda x: scores[x], reverse=True)


# ── 임베딩 API ────────────────────────────────────────────────────────────────

def _get_client() -> genai.Client:
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "axial-device-460408-i9")
    return genai.Client(vertexai=True, project=project, location="us-central1")


def _embed_query(
    client: genai.Client, model: str, query: str, dim: int | None
) -> tuple[list[float], float]:
    cfg = types.EmbedContentConfig(task_type="RETRIEVAL_QUERY")
    if dim is not None:
        cfg = types.EmbedContentConfig(task_type="RETRIEVAL_QUERY", output_dimensionality=dim)
    t0 = time.perf_counter()
    resp = client.models.embed_content(model=model, contents=[query], config=cfg)
    latency_ms = (time.perf_counter() - t0) * 1000
    return list(resp.embeddings[0].values), latency_ms


def _cosine(a: list[float], b: list[float]) -> float:
    va, vb = np.array(a, dtype=np.float32), np.array(b, dtype=np.float32)
    denom = np.linalg.norm(va) * np.linalg.norm(vb)
    return float(np.dot(va, vb) / denom) if denom > 0 else 0.0


# ── 평가 단위 ─────────────────────────────────────────────────────────────────

def _run_queries(
    ranked_fn,  # query -> list[str] (ranked item IDs)
    queries: list[dict],
) -> tuple[list[dict], dict]:
    query_results = []
    for q in queries:
        ranked = ranked_fn(q["query"])
        m = _metrics(ranked, q["expected_ids"])
        query_results.append({
            "query": q["query"],
            "type": q.get("type", "unknown"),
            "expected_ids": q["expected_ids"],
            "top5": ranked[:5],
            **m,
        })
    return query_results, _avg_metrics(query_results)


def _stratified(query_results: list[dict]) -> dict[str, dict]:
    by_type: dict[str, list] = defaultdict(list)
    for r in query_results:
        by_type[r["type"]].append(r)
    return {t: _avg_metrics(rs) for t, rs in by_type.items()}


async def evaluate_combo(
    client: genai.Client,
    embed_path: Path,
    queries: list[dict],
    bm25_ranked_cache: dict[str, dict],   # strategy -> {query -> full_ranked_ids}
    query_vec_cache: dict[tuple, list[float]],  # (model, dim, query) -> vector
) -> list[dict]:
    embed_data = json.loads(embed_path.read_text(encoding="utf-8"))  # noqa: ASYNC240
    items = embed_data["items"]
    model = embed_data["model"]
    dim = embed_data["dimension"]
    strategy = embed_data["strategy"]
    item_ids = [item["id"] for item in items]
    doc_vecs = [item["vector"] for item in items]

    results = []

    # ── BM25 단독 (전략당 1회만 계산) ──
    if strategy not in bm25_ranked_cache:
        corpus = [item["doc_text"] for item in items]
        bm25_ranked_cache[strategy] = {}
        for q in queries:
            indices = _bm25_rank(corpus, q["query"])
            bm25_ranked_cache[strategy][q["query"]] = [item_ids[i] for i in indices]

        def bm25_fn(query: str, _s: str = strategy) -> list[str]:
            return bm25_ranked_cache[_s][query]

        bm25_qr, bm25_avg = _run_queries(bm25_fn, queries)
        results.append({
            "kind": "bm25",
            "model": "BM25",
            "dimension": None,
            "strategy": strategy,
            "label": f"BM25 × {strategy}",
            "avg": bm25_avg,
            "by_type": _stratified(bm25_qr),
            "queries": bm25_qr,
        })

    # ── Vector 단독 ──
    # query embedding은 (model, dim, query) 캐시 — 전략이 달라도 재사용
    async def _get_query_vec(query: str) -> list[float]:
        key = (model, dim, query)
        if key not in query_vec_cache:
            vec, _ = await asyncio.to_thread(_embed_query, client, model, query, dim)
            query_vec_cache[key] = vec
        return query_vec_cache[key]

    vec_full_ranked: dict[str, list[str]] = {}  # 전체 랭킹 — RRF에 사용
    vec_qr = []
    for q in queries:
        q_vec = await _get_query_vec(q["query"])
        scores = sorted(
            [(item_ids[i], _cosine(q_vec, doc_vecs[i])) for i in range(len(items))],
            key=lambda x: x[1], reverse=True,
        )
        full_ranked = [s[0] for s in scores]
        vec_full_ranked[q["query"]] = full_ranked  # RRF용 전체 보존
        m = _metrics(full_ranked, q["expected_ids"])
        vec_qr.append({
            "query": q["query"], "type": q.get("type", "unknown"),
            "expected_ids": q["expected_ids"],
            "top5": full_ranked[:5],  # 출력용만 잘라냄
            **m,
        })

    results.append({
        "kind": "vector",
        "model": model,
        "dimension": dim,
        "strategy": strategy,
        "label": f"vec:{model}@{dim} × {strategy}",
        "avg": _avg_metrics(vec_qr),
        "by_type": _stratified(vec_qr),
        "queries": vec_qr,
    })

    # ── RRF (BM25 전체 + Vector 전체) ──
    rrf_qr = []
    for q in queries:
        bm25_full = bm25_ranked_cache[strategy][q["query"]]  # 전체 BM25 랭킹
        vec_full = vec_full_ranked[q["query"]]               # 전체 vector 랭킹
        rrf_r = _rrf_fuse(bm25_full, vec_full)
        m = _metrics(rrf_r, q["expected_ids"])
        rrf_qr.append({
            "query": q["query"], "type": q.get("type", "unknown"),
            "expected_ids": q["expected_ids"], "top5": rrf_r[:5], **m,
        })
    results.append({
        "kind": "rrf",
        "model": f"RRF(BM25+{model}@{dim})",
        "dimension": dim,
        "strategy": strategy,
        "label": f"rrf:{model}@{dim} × {strategy}",
        "avg": _avg_metrics(rrf_qr),
        "by_type": _stratified(rrf_qr),
        "queries": rrf_qr,
    })

    return results


async def main(analysis_fp: str | None = None, *, allow_partial: bool = False) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    queries = json.loads(GOLD_PATH.read_text(encoding="utf-8"))

    if analysis_fp is None:
        # 최신 analysis artifact 기준으로 fp 결정 — embedding mtime이 아님
        analysis_files = [f for f in ANALYSIS_DIR.glob("*.json") if f.is_file()]
        if not analysis_files:
            print("[ERROR] artifacts/analysis/ 에 파일 없음 — analyze.py 먼저 실행")
            return
        analysis_fp = max(analysis_files, key=lambda f: f.stat().st_mtime).stem

    embed_fp_dir = EMBED_DIR / analysis_fp
    if not embed_fp_dir.exists():
        print(f"[ERROR] 최신 analysis(fp={analysis_fp})의 embedding 없음 — embed.py 실행 필요")
        return
    embed_files = sorted(embed_fp_dir.glob("*.json"))
    if not embed_files:
        print(f"[ERROR] {embed_fp_dir} 에 임베딩 파일 없음")
        return

    # ── 캐시 정합성 검증 ──────────────────────────────────────────────────────

    # 현재 analysis artifact hash
    analysis_path = ANALYSIS_DIR / f"{analysis_fp}.json"
    if not analysis_path.exists():
        print(f"[ERROR] analysis artifact 없음: {analysis_path}")
        return
    analysis_data = json.loads(analysis_path.read_text(encoding="utf-8"))  # noqa: ASYNC240
    current_ahash = _analysis_hash(analysis_data["items"])

    # embedding 파일들의 analysis_hash 수집
    embed_hashes: dict[str, list[str]] = {}
    for ef in embed_files:
        h = json.loads(ef.read_text(encoding="utf-8")).get("analysis_hash", "missing")  # noqa: ASYNC240
        embed_hashes.setdefault(h, []).append(ef.name)

    if set(embed_hashes) != {current_ahash}:
        print("[ERROR] embedding artifact가 현재 analysis와 일치하지 않습니다. embed.py 를 다시 실행하세요.")
        for h, files in embed_hashes.items():
            marker = "← current" if h == current_ahash else "← stale"
            print(f"  {h} {marker}: {len(files)}개 파일")
        return

    # 누락 조합 검증 — 기본은 중단, --allow-partial 시에만 계속
    expected = expected_embed_names()
    found = {ef.name for ef in embed_files}
    missing = expected - found
    if missing:
        level = "[WARN]" if allow_partial else "[ERROR]"
        print(f"{level} embedding {len(missing)}개 조합 누락 (예상 {len(expected)}개 중 {len(found)}개 존재):")
        for name in sorted(missing):
            print(f"  ✗ {name.removesuffix('.json')}")
        if not allow_partial:
            print("부분 결과로 평가하려면 --allow-partial 을 추가하세요.")
            return
        print()

    client = _get_client()
    print(f"analysis_fp={analysis_fp}  combos={len(embed_files)}  queries={len(queries)}\n")

    all_results = []
    bm25_cache: dict[str, dict] = {}
    query_vec_cache: dict[tuple, list[float]] = {}

    for embed_path in embed_files:
        print(f"[{embed_path.stem}]", flush=True)
        try:
            combo_results = await evaluate_combo(
                client, embed_path, queries, bm25_cache, query_vec_cache
            )
            all_results.extend(combo_results)
        except Exception as exc:
            print(f"  [ERROR] {exc}")

    # ── 요약 테이블 ──
    sorted_results = sorted(all_results, key=lambda x: x["avg"]["ndcg@5"], reverse=True)
    print("\n" + "=" * 100)
    print(f"{'레이블':<55} {'HitRate@3':>10} {'Recall@5':>10} {'MRR':>8} {'nDCG@5':>8}")
    print("-" * 100)
    for r in sorted_results:
        a = r["avg"]
        print(f"{r['label']:<55} {a['hit_rate@3']:>10.3f} {a['recall@5']:>10.3f} {a['mrr']:>8.3f} {a['ndcg@5']:>8.3f}")

    # ── 핵심 쿼리 상세 ──
    print("\n\n[핵심 쿼리 '화장품' top-5]")
    for r in sorted_results[:6]:
        qr = next((q for q in r["queries"] if q["query"] == "화장품"), None)
        if qr is None:
            continue
        hit = "✅" if qr["hit_rate@3"] == 1.0 else ("△" if qr["recall@5"] > 0 else "❌")
        print(f"  {hit} {r['label'][:50]:<50} → {qr['top5']}")

    # ── 쿼리 유형별 집계 ──
    print("\n[쿼리 유형별 nDCG@5 (상위 3 조합)]")
    for r in sorted_results[:3]:
        print(f"\n  {r['label']}")
        for qtype, m in sorted(r["by_type"].items()):
            print(f"    {qtype:<25} nDCG@5={m['ndcg@5']:.3f}  mrr={m['mrr']:.3f}")

    # ── 저장 ──
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = RESULTS_DIR / f"{ts}.json"
    out_path.write_text(
        json.dumps(
            {"run_at": ts, "analysis_fp": analysis_fp, "results": all_results},
            ensure_ascii=False, indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\n결과 저장: {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", default=None)
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="25개 미만 embedding 조합이 있어도 평가 계속 (기본: 중단)",
    )
    args = parser.parse_args()
    asyncio.run(main(args.analysis_fp, allow_partial=args.allow_partial))
