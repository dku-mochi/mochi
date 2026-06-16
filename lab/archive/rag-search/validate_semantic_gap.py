"""semantic_gap_queries.json 평가 누수 검사.

각 query가 expected_ids 기록의 다음 필드에 직접 포함되어 있으면 평가 누수로 간주한다:
  - id
  - 원본 입력 (text, url, user_memo)
  - summary
  - intent labels
  - payload 값들
  - entities 값

semantic_expansion 필드는 검사 대상에서 제외한다
(expansion 자체가 gap 단어를 포함하도록 설계되었으므로).

누수 발견 시 해당 query·항목·필드를 출력하고 exit code 1로 종료한다.

실행 (mochi-backend 디렉토리에서):
  uv run --group lab python "../lab/active/rag-search/validate_semantic_gap.py" [--analysis-fp <fp>]
"""

import argparse
import json
import sys
from pathlib import Path

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
GOLD_PATH = LAB_ROOT / "gold" / "semantic_gap_queries.json"


def _check_leakage(item: dict, query: str) -> list[str]:
    """query 소문자가 포함된 필드 목록을 반환한다."""
    hits: list[str] = []
    q = query.lower()

    if q in item["id"].lower():
        hits.append(f"id={item['id']}")

    for field in ("image", "text", "url", "user_memo"):
        val = item.get(field)
        if val and q in str(val).lower():
            hits.append(f"input.{field}")

    a = item.get("analysis", {})

    if q in a.get("summary", "").lower():
        hits.append("analysis.summary")

    for inst in a.get("intent_instances", []):
        label = inst.get("label", "")
        if label and q in label.lower():
            hits.append(f"intent_label={label!r}")

    for inst in a.get("intent_instances", []):
        for field, val in inst.get("payload", {}).items():
            if val and q in str(val).lower():
                hits.append(f"payload.{field}={str(val)[:60]!r}")

    for e in a.get("entities", []):
        val = e.get("value", "")
        if val and q in str(val).lower():
            hits.append(f"entity.{e.get('kind', '?')}={val!r}")

    return hits


def main(analysis_fp: str | None = None) -> None:
    if analysis_fp is None:
        candidates = [f for f in ANALYSIS_DIR.glob("*.json") if f.is_file()]
        if not candidates:
            print("[ERROR] artifacts/analysis/ 에 파일 없음")
            sys.exit(1)
        analysis_path = max(candidates, key=lambda f: f.stat().st_mtime)
    else:
        analysis_path = ANALYSIS_DIR / f"{analysis_fp}.json"

    if not analysis_path.exists():
        print(f"[ERROR] analysis artifact 없음: {analysis_path}")
        sys.exit(1)

    data = json.loads(analysis_path.read_text(encoding="utf-8"))
    item_map = {item["id"]: item for item in data["items"]}

    queries = json.loads(GOLD_PATH.read_text(encoding="utf-8"))

    violations: list[dict] = []
    unknown_ids: list[str] = []

    for q in queries:
        query_text = q["query"]
        for eid in q["expected_ids"]:
            item = item_map.get(eid)
            if item is None:
                unknown_ids.append(f"query={query_text!r}  expected_id={eid!r}")
                continue
            hits = _check_leakage(item, query_text)
            if hits:
                violations.append({
                    "query": query_text,
                    "expected_id": eid,
                    "found_in": hits,
                })

    if unknown_ids:
        print(f"[FAIL] analysis artifact에 없는 expected_id {len(unknown_ids)}건:")
        for msg in unknown_ids:
            print(f"  {msg}")

    if violations:
        print(f"[FAIL] 평가 누수 {len(violations)}건 발견:\n")
        for v in violations:
            print(f"  query={v['query']!r}  expected_id={v['expected_id']!r}")
            for field in v["found_in"]:
                print(f"    >> {field}")
    if unknown_ids or violations:
        sys.exit(1)

    total_pairs = sum(len(q["expected_ids"]) for q in queries)
    print(
        f"[OK] 평가 누수 없음 — {len(queries)}개 쿼리 × {total_pairs}쌍 검사 완료"
        f"  (analysis_fp={analysis_path.stem})"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="semantic_gap_queries.json 평가 누수 검사")
    parser.add_argument("--analysis-fp", default=None, help="분석 artifact 파일명 (확장자 제외)")
    args = parser.parse_args()
    main(args.analysis_fp)
