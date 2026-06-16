"""1.5단계: analysis artifact → semantic_expansion 생성.

각 기록의 summary/labels/payload/entities를 참고해 Gemini가
원문에 없는 상위 개념·동의어·관련 맥락 표현 3~5개를 생성한다.

저장: artifacts/expansion/{analysis_fp}.json
캐시: item_hash 가 동일하면 스킵.

실행 (mochi-backend 디렉토리에서):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \\
  uv run python "../lab/active/rag-search/expand.py" [--analysis-fp <fp>]
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from contextlib import contextmanager
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
REPO_ROOT = Path(__file__).resolve().parents[3]
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
EXPANSION_DIR = LAB_ROOT / "artifacts" / "expansion"

load_dotenv(REPO_ROOT / "mochi-backend" / ".env", override=False)
_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite")
_LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "global")

_PROMPT_TEMPLATE = """\
너는 검색 인덱싱 전문가다. 아래 기록에 대한 semantic expansion 키워드를 생성해라.

규칙:
- summary·intent·payload·entities에 직접 등장하거나 단순 형태 변형된 단어는 절대 포함하지 않는다.
- 사용자가 이 기록을 나중에 검색할 때 입력할 가능성이 높은 상위 개념·동의어·관련 맥락 표현만 생성한다.
- 지나치게 광범위하거나 관련성이 낮은 표현은 제외한다.
- 정확히 3~5개를 생성한다.
- JSON 배열만 반환한다. 예: ["군대", "병역", "입대", "군복무"]

기록:
{context}

JSON 배열:"""

_CONFIG_HASH = hashlib.sha256(
    f"{_MODEL}\n{_LOCATION}\n{_PROMPT_TEMPLATE}".encode()
).hexdigest()[:12]


@contextmanager
def _exclusive_lock(path: Path):
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise RuntimeError(f"다른 expand.py 실행이 진행 중입니다: {path}") from exc
    try:
        os.close(fd)
        yield
    finally:
        path.unlink(missing_ok=True)


def _get_client() -> genai.Client:
    creds_file = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if creds_file and not Path(creds_file).exists():
        print(f"[WARN] GOOGLE_APPLICATION_CREDENTIALS 파일 없음: {creds_file!r}, ADC로 대체")
        del os.environ["GOOGLE_APPLICATION_CREDENTIALS"]
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "axial-device-460408-i9")
    return genai.Client(vertexai=True, project=project, location=_LOCATION)


def _item_hash(item: dict) -> str:
    a = item.get("analysis", {})
    raw = json.dumps(
        {
            "summary": a.get("summary", ""),
            "intent_instances": a.get("intent_instances", []),
            "entities": a.get("entities", []),
            "config_hash": _CONFIG_HASH,
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(raw.encode()).hexdigest()[:8]


def _build_context(item: dict) -> str:
    a = item["analysis"]
    labels = " ".join(
        inst["label"] for inst in a["intent_instances"] if inst.get("label")
    )
    payload_parts = []
    for inst in a["intent_instances"]:
        p = inst.get("payload", {})
        for field in ("title", "topic", "note", "person", "deadline", "date"):
            if p.get(field):
                payload_parts.append(f"{field}: {p[field]}")
    entity_parts = [f"{e['kind']}: {e['value']}" for e in a.get("entities", [])]

    lines = [f"summary: {a['summary']}"]
    if labels:
        lines.append(f"intent: {labels}")
    if payload_parts:
        lines.append(" ".join(payload_parts))
    if entity_parts:
        lines.append("entities: " + " ".join(entity_parts))
    return "\n".join(lines)


def _gen_expansion(client: genai.Client, item: dict) -> list[str]:
    prompt = _PROMPT_TEMPLATE.format(context=_build_context(item))
    for attempt in range(4):
        try:
            resp = client.models.generate_content(
                model=_MODEL,
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    temperature=0.0,
                ),
            )
            raw = resp.text.strip()
            raw = re.sub(r"^```(?:json)?\s*", "", raw)
            raw = re.sub(r"\s*```$", "", raw)
            terms = json.loads(raw)
            if not isinstance(terms, list):
                raise ValueError(f"리스트가 아님: {raw[:80]}")
            return [str(t).strip() for t in terms if str(t).strip()]
        except Exception as exc:
            if attempt == 3:
                raise
            delay = 3.0 * (attempt + 1)
            print(f"  [retry {attempt + 1}] {exc}  (wait {delay:.0f}s)")
            time.sleep(delay)
    return []


def main(analysis_fp: str | None = None) -> None:
    EXPANSION_DIR.mkdir(parents=True, exist_ok=True)

    if analysis_fp is None:
        candidates = [f for f in ANALYSIS_DIR.glob("*.json") if f.is_file()]
        if not candidates:
            print("[ERROR] artifacts/analysis/ 에 파일 없음 — analyze.py 먼저 실행")
            return
        analysis_path = max(candidates, key=lambda f: f.stat().st_mtime)
        analysis_fp = analysis_path.stem
    else:
        analysis_path = ANALYSIS_DIR / f"{analysis_fp}.json"

    data = json.loads(analysis_path.read_text(encoding="utf-8"))
    items = data["items"]

    out_path = EXPANSION_DIR / f"{analysis_fp}.json"
    lock_path = out_path.with_suffix(".lock")
    with _exclusive_lock(lock_path):
        existing: dict[str, dict] = {}
        if out_path.exists():
            prev = json.loads(out_path.read_text(encoding="utf-8"))
            if prev.get("config_hash") == _CONFIG_HASH:
                existing = prev.get("items", {})

        client = _get_client()
        print(f"analysis_fp={analysis_fp}  items={len(items)}  model={_MODEL}  location={_LOCATION}\n")

        results: dict[str, dict] = dict(existing)
        for item in items:
            iid = item["id"]
            ihash = _item_hash(item)
            if iid in results and results[iid].get("item_hash") == ihash:
                print(f"[skip ] {iid}")
                continue
            print(f"[run  ] {iid}", flush=True)
            try:
                terms = _gen_expansion(client, item)
                results[iid] = {"item_hash": ihash, "expansion": terms}
                print(f"  → {terms}")
            except Exception as exc:
                print(f"  [ERROR] {exc}")

        if len(results) != len(items):
            raise RuntimeError(
                f"semantic expansion 생성 미완료: expected={len(items)} actual={len(results)}"
            )

        artifact = {
            "analysis_fp": analysis_fp,
            "model": _MODEL,
            "location": _LOCATION,
            "config_hash": _CONFIG_HASH,
            "items": results,
        }
        tmp_path = out_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(artifact, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_path.replace(out_path)
        print(f"\n✅ {out_path}  ({len(results)}개)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis-fp", default=None)
    args = parser.parse_args()
    main(args.analysis_fp)
