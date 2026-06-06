"""embed.py + eval_retrieval.py 공용 상수·유틸리티.

MODELS, STRATEGY_NAMES 를 단일 원천으로 유지한다.
analysis_hash 와 expected_embed_names 는 캐시 정합성 검증에 쓰인다.
"""

import hashlib
import json
from typing import Any

# (model, output_dimensionality) — None 이면 모델 기본값
MODELS: list[tuple[str, int | None]] = [
    ("text-multilingual-embedding-002", 256),
    ("text-multilingual-embedding-002", 768),
    ("gemini-embedding-001", 256),
    ("gemini-embedding-001", 768),
    ("gemini-embedding-001", 1536),
]

# embed.py STRATEGIES dict 의 키와 반드시 일치해야 함
STRATEGY_NAMES: list[str] = [
    "summary",
    "summary+labels",
    "summary+labels+payload",
    "summary+labels+payload+entities",
    "structured_fields",
]


def analysis_hash(items: list[dict[str, Any]]) -> str:
    """analysis items 직렬화 → sha256[:12].

    embed.py 가 embedding artifact 에 기록하고,
    eval_retrieval.py 가 현재 analysis artifact 와 비교한다.
    """
    raw = json.dumps(items, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def expected_embed_names() -> set[str]:
    """embed.py 가 생성해야 하는 파일명 집합 (25개 = 5모델×차원 × 5전략)."""
    names: set[str] = set()
    for model, dim in MODELS:
        dim_tag = str(dim) if dim is not None else "default"
        for strategy in STRATEGY_NAMES:
            label = f"{model}@{dim_tag}_{strategy}"
            names.add(label.replace("/", "_") + ".json")
    return names
