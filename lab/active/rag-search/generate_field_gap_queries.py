"""Generate one field-gap keyword query from each analyzed document summary.

The generated keyword must not directly contain values from:
summary, intent, title, topic, organization, or note.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
REPO_ROOT = Path(__file__).resolve().parents[3]
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
QUERY_DIR = LAB_ROOT / "artifacts" / "generated_queries"

load_dotenv(REPO_ROOT / "mochi-backend" / ".env", override=False)
MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "global")

PROMPT = """\
너는 검색 평가용 키워드 작성자다.

아래 summary만 이해한 뒤, 사용자가 이 기록을 찾기 위해 입력할 법한 상위 맥락의 검색 키워드 하나를 작성해라.

규칙:
- summary에 직접 포함된 단어·문구를 사용하지 않는다.
- 단순 띄어쓰기 변경, 조사 변경, 동일 단어 반복도 사용하지 않는다.
- summary의 상위 개념이나 간접적인 맥락을 사용한다.
- 구체적인 제목이나 문장 대신 사용자가 검색창에 입력할 법한 일반적인 분류어를 만든다.
- 문장이나 질문을 만들지 않는다.
- 조사와 서술어를 사용하지 않는다.
- 반드시 공백 없는 단일 키워드 한 단어만 만든다.
- 여러 단어, 띄어쓰기, 쉼표, 문장부호를 사용하지 않는다.
- 좋은 예시: 건강, 데이트, 밥, 여행, 공부, 취업, 쇼핑, 운동
- JSON 객체만 반환한다.

반환 형식:
{{"query": "검색 키워드", "reason": "이 키워드가 summary의 상위 맥락인 이유"}}

summary:
{summary}
"""
CONFIG_HASH = hashlib.sha256(f"{MODEL}\n{LOCATION}\n{PROMPT}".encode()).hexdigest()[:12]

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


def _get_client() -> genai.Client:
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "axial-device-460408-i9")
    return genai.Client(vertexai=True, project=project, location=LOCATION)


def _fields(item: dict) -> dict[str, str]:
    analysis = item["analysis"]
    labels: list[str] = []
    titles: list[str] = []
    topics: list[str] = []
    notes: list[str] = []
    for inst in analysis.get("intent_instances", []):
        if inst.get("label"):
            labels.append(str(inst["label"]))
        payload = inst.get("payload", {})
        for values, key in ((titles, "title"), (topics, "topic"), (notes, "note")):
            if payload.get(key):
                values.append(str(payload[key]))
    organizations = [
        str(entity["value"])
        for entity in analysis.get("entities", [])
        if str(entity.get("kind", "")).lower() in {"organization", "org"}
        and entity.get("value")
    ]
    return {
        "summary": str(analysis.get("summary", "")),
        "intent": " ".join(labels),
        "title": " ".join(titles),
        "topic": " ".join(topics),
        "organization": " ".join(organizations),
        "note": " ".join(notes),
    }


def _normalize(text: str) -> str:
    return re.sub(r"[\W_]+", "", text.lower())


def _leaks(query: str, fields: dict[str, str]) -> list[str]:
    normalized_query = _normalize(query)
    query_terms = {
        _normalize(term)
        for term in re.findall(r"[0-9A-Za-z가-힣]+", query)
        if len(_normalize(term)) >= 2 and _normalize(term) not in COMMON_QUERY_TERMS
    }
    hits = []
    for name, value in fields.items():
        normalized_value = _normalize(value)
        if (
            normalized_query
            and normalized_query in normalized_value
            or any(term in normalized_value for term in query_terms)
        ):
            hits.append(name)
    return hits


def _is_keyword(query: str) -> bool:
    return re.fullmatch(r"[0-9A-Za-z가-힣]+", query) is not None and len(query) <= 20


def _generate(client: genai.Client, item: dict) -> dict:
    fields = _fields(item)
    prompt = PROMPT.format(summary=json.dumps(fields["summary"], ensure_ascii=False))
    for attempt in range(8):
        response = client.models.generate_content(
            model=MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                temperature=0.4,
            ),
        )
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", response.text.strip())
        result = json.loads(raw)
        query = str(result.get("query", "")).strip()
        leaks = _leaks(query, fields)
        if query and _is_keyword(query) and not leaks:
            return {
                "query": query,
                "type": "generated_summary_field_gap",
                "expected_ids": [item["id"]],
                "reason": str(result.get("reason", "")).strip(),
            }
        problem = (
            f"다음 필드 표현과 겹친다: {leaks}"
            if leaks
            else "공백과 문장부호가 없는 단일 키워드 한 단어 형식이 아니다"
        )
        prompt += f"\n\n이전 결과 {query!r}는 사용할 수 없다. 이유: {problem}. 다시 작성해라."
        if attempt < 7:
            time.sleep(2.0 * (attempt + 1))
    raise ValueError(f"필드 미포함 쿼리 생성 실패: {item['id']}")


def main(analysis_fp: str | None) -> None:
    candidates = [path for path in ANALYSIS_DIR.glob("*.json") if path.is_file()]
    if analysis_fp is None:
        if not candidates:
            raise FileNotFoundError("analysis artifact 없음")
        analysis_path = max(candidates, key=lambda path: path.stat().st_mtime)
    else:
        analysis_path = ANALYSIS_DIR / f"{analysis_fp}.json"

    data = json.loads(analysis_path.read_text(encoding="utf-8"))
    client = _get_client()
    QUERY_DIR.mkdir(parents=True, exist_ok=True)
    out_path = QUERY_DIR / f"{analysis_path.stem}.json"
    existing: dict[str, dict] = {}
    if out_path.exists():
        previous = json.loads(out_path.read_text(encoding="utf-8"))
        if previous.get("config_hash") == CONFIG_HASH:
            existing = {
                query["expected_ids"][0]: query for query in previous.get("queries", [])
            }

    queries_by_id = dict(existing)
    failures = []
    for item in data["items"]:
        if item["id"] in queries_by_id:
            print(f"[skip] {item['id']}")
            continue
        print(f"[run ] {item['id']}", flush=True)
        try:
            query = _generate(client, item)
            queries_by_id[item["id"]] = query
            print(f"  → {query['query']}")
        except Exception as exc:
            failures.append(f"{item['id']}: {exc}")
            print(f"  [ERROR] {exc}")
        finally:
            artifact = {
                "analysis_fp": analysis_path.stem,
                "model": MODEL,
                "location": LOCATION,
                "generation_source": "summary",
                "config_hash": CONFIG_HASH,
                "query_count": len(queries_by_id),
                "queries": list(queries_by_id.values()),
            }
            tmp_path = out_path.with_suffix(".tmp")
            tmp_path.write_text(
                json.dumps(artifact, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            tmp_path.replace(out_path)

    print(f"\n✅ {out_path} ({len(queries_by_id)}개)")
    if failures:
        raise RuntimeError(f"쿼리 생성 실패 {len(failures)}개: {failures}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", default=None)
    args = parser.parse_args()
    main(args.analysis_fp)
