"""Evaluate Gemini-generated field-gap queries using only the five base strategies."""

import argparse
import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
REPO_ROOT = Path(__file__).resolve().parents[3]
EMBED_DIR = LAB_ROOT / "artifacts" / "embeddings"
QUERY_DIR = LAB_ROOT / "artifacts" / "generated_queries"
RESULTS_DIR = LAB_ROOT / "results" / "field-gap"

load_dotenv(REPO_ROOT / "mochi-backend" / ".env", override=False)

sys.path.insert(0, str(LAB_ROOT))
from eval_retrieval import _get_client, evaluate_combo  # noqa: E402

BASE_STRATEGIES = {
    "summary",
    "summary+labels",
    "summary+labels+payload",
    "summary+labels+payload+entities",
    "structured_fields",
}


def _best_by(results: list[dict], field: str) -> list[dict]:
    best: dict[str, dict] = {}
    for result in results:
        if result["kind"] != "vector":
            continue
        key = str(result[field])
        if key not in best or result["avg"]["ndcg@5"] > best[key]["avg"]["ndcg@5"]:
            best[key] = result
    return sorted(best.values(), key=lambda result: result["avg"]["ndcg@5"], reverse=True)


async def main(analysis_fp: str) -> None:
    query_artifact = json.loads(
        (QUERY_DIR / f"{analysis_fp}.json").read_text(encoding="utf-8")
    )
    queries = query_artifact["queries"]
    embed_files = []
    for path in sorted((EMBED_DIR / analysis_fp).glob("*.json")):
        artifact = json.loads(path.read_text(encoding="utf-8"))
        if artifact["strategy"] in BASE_STRATEGIES:
            embed_files.append(path)

    client = _get_client()
    all_results = []
    bm25_cache: dict[str, dict] = {}
    query_vec_cache: dict[tuple, list[float]] = {}
    for path in embed_files:
        print(f"[{path.stem}]", flush=True)
        all_results.extend(
            await evaluate_combo(client, path, queries, bm25_cache, query_vec_cache)
        )

    vector_results = sorted(
        (result for result in all_results if result["kind"] == "vector"),
        key=lambda result: result["avg"]["ndcg@5"],
        reverse=True,
    )
    print("\n[상위 Vector 조합]")
    for result in vector_results[:10]:
        similarity = result["similarity"]
        print(
            f"{result['label']}: nDCG@5={result['avg']['ndcg@5']:.3f} "
            f"Hit@3={result['avg']['hit_rate@3']:.3f} "
            f"정답유사도={similarity['expected_similarity']:.4f} "
            f"margin={similarity['similarity_margin']:+.4f}"
        )

    for title, field in (
        ("모델별 최고 조합", "model"),
        ("차원별 최고 조합", "dimension"),
        ("문서 전략별 최고 조합", "strategy"),
    ):
        print(f"\n[{title}]")
        for result in _best_by(all_results, field):
            print(f"{result[field]}: {result['label']} nDCG@5={result['avg']['ndcg@5']:.3f}")

    best_by_kind: dict[str, dict] = {}
    for result in all_results:
        kind = result["kind"]
        if kind not in best_by_kind or result["avg"]["ndcg@5"] > best_by_kind[kind]["avg"]["ndcg@5"]:
            best_by_kind[kind] = result
    print("\n[검색 방식별 최고 조합]")
    for kind, result in sorted(best_by_kind.items()):
        print(f"{kind}: {result['label']} nDCG@5={result['avg']['ndcg@5']:.3f}")

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = RESULTS_DIR / f"{timestamp}.json"
    out_path.write_text(
        json.dumps(
            {
                "run_at": timestamp,
                "analysis_fp": analysis_fp,
                "query_count": len(queries),
                "strategies": sorted(BASE_STRATEGIES),
                "results": all_results,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\n결과 저장: {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", required=True)
    args = parser.parse_args()
    asyncio.run(main(args.analysis_fp))
