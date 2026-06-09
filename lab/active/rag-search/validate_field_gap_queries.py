"""Validate generated queries against the six source document fields."""

import argparse
import json
import re
import sys
from pathlib import Path

LAB_ROOT = Path(__file__).parent
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
QUERY_DIR = LAB_ROOT / "artifacts" / "generated_queries"

COMMON_QUERY_TERMS = {
    "관련",
    "검색",
    "기록",
    "정보",
    "확인",
    "방법",
    "자료",
    "내용",
    "정리",
    "저장",
    "나중",
    "위한",
    "추천",
}


def _normalize(text: str) -> str:
    return re.sub(r"[\W_]+", "", text.lower())


def _is_keyword(query: str) -> bool:
    return re.fullmatch(r"[0-9A-Za-z가-힣]+", query) is not None and len(query) <= 20


def _fields(item: dict) -> dict[str, str]:
    analysis = item["analysis"]
    values: dict[str, list[str]] = {
        "intent": [],
        "title": [],
        "topic": [],
        "organization": [],
        "note": [],
    }
    for inst in analysis.get("intent_instances", []):
        if inst.get("label"):
            values["intent"].append(str(inst["label"]))
        payload = inst.get("payload", {})
        for name in ("title", "topic", "note"):
            if payload.get(name):
                values[name].append(str(payload[name]))
    for entity in analysis.get("entities", []):
        if str(entity.get("kind", "")).lower() in {"organization", "org"}:
            values["organization"].append(str(entity.get("value", "")))
    return {
        "summary": str(analysis.get("summary", "")),
        **{name: " ".join(parts) for name, parts in values.items()},
    }


def main(analysis_fp: str) -> None:
    analysis = json.loads(
        (ANALYSIS_DIR / f"{analysis_fp}.json").read_text(encoding="utf-8")
    )
    generated = json.loads(
        (QUERY_DIR / f"{analysis_fp}.json").read_text(encoding="utf-8")
    )
    item_map = {item["id"]: item for item in analysis["items"]}
    violations = []
    for query in generated["queries"]:
        expected_id = query["expected_ids"][0]
        item = item_map.get(expected_id)
        if item is None:
            violations.append((query["query"], expected_id, ["unknown_id"]))
            continue
        if not _is_keyword(query["query"]):
            violations.append((query["query"], expected_id, ["not_keyword"]))
            continue
        normalized_query = _normalize(query["query"])
        query_terms = {
            _normalize(term)
            for term in re.findall(r"[0-9A-Za-z가-힣]+", query["query"])
            if len(_normalize(term)) >= 2 and _normalize(term) not in COMMON_QUERY_TERMS
        }
        hits = [
            name
            for name, value in _fields(item).items()
            if (
                normalized_query
                and normalized_query in _normalize(value)
                or any(term in _normalize(value) for term in query_terms)
            )
        ]
        if hits:
            violations.append((query["query"], expected_id, hits))

    if violations:
        for query, expected_id, hits in violations:
            print(f"[FAIL] {query!r} → {expected_id}: {hits}")
        sys.exit(1)
    print(f"[OK] field-gap query {len(generated['queries'])}개 누수 없음")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", required=True)
    args = parser.parse_args()
    main(args.analysis_fp)
