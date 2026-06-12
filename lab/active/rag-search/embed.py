"""2단계: AnalysisResult → 임베딩 벡터 생성 및 캐시.

각 (model, dimension, document_strategy) 조합으로 벡터를 생성하고
artifacts/embeddings/{analysis_fp}/{model}@{dim}_{strategy}.json 에 저장한다.
analysis artifact가 변경됐으면 해당 embedding을 재생성한다.

실행 (mochi-backend 디렉토리에서):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \\
  GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \\
  uv run python "../lab/active/rag-search/embed.py" [--analysis-fp <fp>]
"""

import argparse
import asyncio
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import httpx
from google import genai
from google.genai import types

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).parent))
from _lab_utils import EXPANSION_STRATEGIES, MODELS, STRATEGY_NAMES, analysis_hash as _analysis_hash  # noqa: E402, I001

LAB_ROOT = Path(__file__).parent
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
EMBED_DIR = LAB_ROOT / "artifacts" / "embeddings"
VOYAGE_EMBEDDINGS_URL = "https://api.voyageai.com/v1/embeddings"


def _labels(item: dict) -> str:
    return " ".join(
        inst["label"] for inst in item["analysis"]["intent_instances"] if inst.get("label")
    )


def _payload_text(item: dict) -> str:
    parts = []
    for inst in item["analysis"]["intent_instances"]:
        p = inst.get("payload", {})
        for field in ("title", "topic", "note", "person", "deadline", "date"):
            if p.get(field):
                parts.append(f"{field}: {p[field]}")
    return " ".join(parts)


def _entity_text(item: dict) -> str:
    return " ".join(
        f"entity.{e['kind']}: {e['value']}"
        for e in item["analysis"].get("entities", [])
    )


def _category(item: dict) -> str:
    return item["analysis"].get("category") or ""


STRATEGIES: dict[str, callable] = {  # keys must match _lab_utils.STRATEGY_NAMES
    "summary": lambda item: item["analysis"]["summary"],
    "summary+labels": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)}"
    ),
    "summary+labels+payload": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)} {_payload_text(item)}"
    ),
    "summary+labels+payload+entities": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)} "
        f"{_payload_text(item)} {_entity_text(item)}"
    ),
    "structured_fields": lambda item: (
        f"summary: {item['analysis']['summary']}\n"
        f"intent: {_labels(item)}\n"
        f"{_payload_text(item)}\n"
        f"{_entity_text(item)}"
    ),
    "summary+semantic_expansion": lambda item: (
        f"summary: {item['analysis']['summary']}"
        + (f" semantic_expansion: {item['_expansion']}" if item.get("_expansion") else "")
    ),
    "summary+labels+semantic_expansion": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)}"
        + (f" semantic_expansion: {item['_expansion']}" if item.get("_expansion") else "")
    ),
    "summary+category": lambda item: (
        f"summary: {item['analysis']['summary']}"
        + (f" category: {_category(item)}" if _category(item) else "")
    ),
    "summary+labels+category": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)}"
        + (f" category: {_category(item)}" if _category(item) else "")
    ),
    "summary+labels+payload+category": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)} {_payload_text(item)}"
        + (f" category: {_category(item)}" if _category(item) else "")
    ),
    "summary+labels+payload+entities+category": lambda item: (
        f"summary: {item['analysis']['summary']} intent: {_labels(item)} "
        f"{_payload_text(item)} {_entity_text(item)}"
        + (f" category: {_category(item)}" if _category(item) else "")
    ),
    "structured_fields+category": lambda item: (
        f"summary: {item['analysis']['summary']}\n"
        f"intent: {_labels(item)}\n"
        f"{_payload_text(item)}\n"
        f"{_entity_text(item)}"
        + (f"\ncategory: {_category(item)}" if _category(item) else "")
    ),
}


assert set(STRATEGIES) == set(STRATEGY_NAMES), (
    f"STRATEGIES keys와 _lab_utils.STRATEGY_NAMES 불일치: {set(STRATEGIES) ^ set(STRATEGY_NAMES)}"
)

_BASE_STRATEGY: dict[str, str] = {
    "summary+semantic_expansion": "summary",
    "summary+labels+semantic_expansion": "summary+labels",
}


def _get_client() -> genai.Client:
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "axial-device-460408-i9")
    return genai.Client(vertexai=True, project=project, location="us-central1")


def _is_voyage_model(model: str) -> bool:
    return model.startswith("voyage-")


def _embed_voyage_batch(
    model: str,
    texts: list[str],
    input_type: str,
    dim: int | None,
) -> tuple[list[list[float]], float]:
    api_key = os.environ.get("VOYAGE_API_KEY")
    if not api_key:
        raise RuntimeError("VOYAGE_API_KEY 환경변수가 필요합니다.")

    payload: dict[str, object] = {
        "input": texts,
        "model": model,
        "input_type": input_type,
    }
    if dim is not None:
        payload["output_dimension"] = dim

    t0 = time.perf_counter()
    with httpx.Client(timeout=60.0) as client:
        for attempt in range(5):
            resp = client.post(
                VOYAGE_EMBEDDINGS_URL,
                headers={"Authorization": f"Bearer {api_key}"},
                json=payload,
            )
            if resp.status_code != 429:
                resp.raise_for_status()
                break
            retry_after = resp.headers.get("Retry-After")
            sleep_seconds = float(retry_after) if retry_after else 20.0 * (attempt + 1)
            print(f"  [rate ] Voyage 429, retry in {sleep_seconds:.0f}s")
            time.sleep(sleep_seconds)
        else:
            resp.raise_for_status()
    latency_ms = (time.perf_counter() - t0) * 1000
    data = resp.json()["data"]
    return [list(row["embedding"]) for row in data], latency_ms


def _embed_batch(
    client: genai.Client,
    model: str,
    texts: list[str],
    task_type: str,
    dim: int | None,
) -> tuple[list[list[float]], float]:
    if _is_voyage_model(model):
        input_type = "document" if task_type == "RETRIEVAL_DOCUMENT" else "query"
        return _embed_voyage_batch(model, texts, input_type, dim)

    cfg = (
        types.EmbedContentConfig(task_type=task_type, output_dimensionality=dim)
        if dim is not None
        else types.EmbedContentConfig(task_type=task_type)
    )
    t0 = time.perf_counter()
    resp = client.models.embed_content(model=model, contents=texts, config=cfg)
    latency_ms = (time.perf_counter() - t0) * 1000
    return [list(e.values) for e in resp.embeddings], latency_ms


async def _run_combo(
    client: genai.Client,
    items: list[dict],
    model: str,
    dim: int | None,
    strategy: str,
    out_path: Path,
    analysis_hash: str,
    expansion_map: dict[str, str] | None = None,
    expansion_hash: str | None = None,
) -> None:
    # 이미 존재하면 analysis hash 비교 — 불일치 시 재생성
    if out_path.exists():  # noqa: ASYNC240
        existing = json.loads(out_path.read_text(encoding="utf-8"))  # noqa: ASYNC240
        expansion_matches = (
            strategy not in EXPANSION_STRATEGIES
            or existing.get("expansion_hash") == expansion_hash
        )
        if existing.get("analysis_hash") == analysis_hash and expansion_matches:
            print(f"  [skip ] {out_path.name}")
            return
        print(f"  [stale] {out_path.name}  source changed, regenerating")

    aug_items = (
        [{**item, "_expansion": expansion_map.get(item["id"], "")} for item in items]
        if expansion_map is not None
        else items
    )
    strategy_fn = STRATEGIES[strategy]
    doc_texts = [strategy_fn(item) for item in aug_items]
    vecs, latency_ms = await asyncio.to_thread(
        _embed_batch, client, model, doc_texts, "RETRIEVAL_DOCUMENT", dim
    )
    actual_dim = len(vecs[0]) if vecs else 0

    if strategy in EXPANSION_STRATEGIES:
        base_fn = STRATEGIES[_BASE_STRATEGY[strategy]]
        records = [
            {"id": item["id"], "doc_text": doc_text, "vector": vec,
             "bm25_doc_text": base_fn(item)}
            for item, vec, doc_text in zip(aug_items, vecs, doc_texts, strict=True)
        ]
    else:
        records = [
            {"id": item["id"], "doc_text": doc_text, "vector": vec}
            for item, vec, doc_text in zip(aug_items, vecs, doc_texts, strict=True)
        ]

    artifact = {
        "analysis_hash": analysis_hash,
        "expansion_hash": expansion_hash if strategy in EXPANSION_STRATEGIES else None,
        "model": model,
        "dimension": actual_dim,
        "strategy": strategy,
        "item_count": len(records),
        "batch_latency_ms": round(latency_ms, 1),
        "vector_bytes_per_item": actual_dim * 4,
        "estimated_total_kb": round(actual_dim * 4 * len(records) / 1024, 1),
        "items": records,
    }
    out_path.write_text(json.dumps(artifact, ensure_ascii=False, indent=2), encoding="utf-8")  # noqa: ASYNC240
    print(f"  [done ] {out_path.name}  dim={actual_dim}  latency={latency_ms:.0f}ms")


async def main(analysis_fp: str | None = None) -> None:
    # 최신 analysis artifact 자동 선택 (mtime 기준)
    if analysis_fp is None:
        candidates = [f for f in ANALYSIS_DIR.glob("*.json") if f.is_file()]
        if not candidates:
            print("[ERROR] artifacts/analysis/ 에 파일 없음 — analyze.py 먼저 실행")
            return
        artifact_path = max(candidates, key=lambda f: f.stat().st_mtime)
        analysis_fp = artifact_path.stem
    else:
        artifact_path = ANALYSIS_DIR / f"{analysis_fp}.json"

    data = json.loads(artifact_path.read_text(encoding="utf-8"))
    items = data["items"]
    ahash = _analysis_hash(items)
    client = _get_client()

    _expansion_map: dict[str, str] | None = None
    _expansion_hash: str | None = None
    exp_path = LAB_ROOT / "artifacts" / "expansion" / f"{analysis_fp}.json"
    if exp_path.exists():
        exp_data = json.loads(exp_path.read_text(encoding="utf-8"))
        expansion_items = exp_data.get("items", {})
        _expansion_map = {
            iid: " ".join(v["expansion"]) if isinstance(v["expansion"], list) else v["expansion"]
            for iid, v in expansion_items.items()
        }
        expected_ids = {item["id"] for item in items}
        missing_ids = expected_ids - set(_expansion_map)
        empty_ids = {iid for iid, text in _expansion_map.items() if not text.strip()}
        if missing_ids or empty_ids:
            raise RuntimeError(
                "semantic expansion artifact 불완전: "
                f"missing={len(missing_ids)} empty={len(empty_ids)}. expand.py를 다시 실행하세요."
            )
        expansion_raw = json.dumps(expansion_items, ensure_ascii=False, sort_keys=True)
        _expansion_hash = hashlib.sha256(expansion_raw.encode()).hexdigest()[:12]
        print(f"expansion_map: {len(_expansion_map)}개 로드")
    else:
        raise RuntimeError("semantic expansion artifact 없음 — expand.py를 먼저 실행하세요.")

    out_dir = EMBED_DIR / analysis_fp
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"analysis_fp={analysis_fp}  analysis_hash={ahash}  items={len(items)}")
    print(f"모델 조합: {MODELS}")
    print(f"전략: {list(STRATEGIES)}\n")

    for model, dim in MODELS:
        dim_tag = str(dim) if dim else "default"
        for strategy in STRATEGIES:
            label = f"{model}@{dim_tag}_{strategy}"
            out_path = out_dir / f"{label.replace('/', '_')}.json"
            print(f"[{label}]", flush=True)
            try:
                await _run_combo(
                    client,
                    items,
                    model,
                    dim,
                    strategy,
                    out_path,
                    ahash,
                    _expansion_map,
                    _expansion_hash,
                )
            except Exception as exc:
                print(f"  [ERROR] {exc}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", default=None)
    args = parser.parse_args()
    asyncio.run(main(args.analysis_fp))
