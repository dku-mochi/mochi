#!/usr/bin/env python3
"""user_memo prompt 수정(classify_and_act@v15) 회귀 테스트 — 이미지-only 분류.

목적: V15 의 user_memo 강화가 **user_memo 가 없는 이미지-only 분류**에서 V14 성능을
유지하는지 raw 출력을 수집한다. 정성 판정(summary/category 의도부합)은 부모 Claude 가
results.json 을 읽고 직접 한다. 이 스크립트는 raw finalize 출력만 충실히 저장한다.

프로덕션 충실도:
- system_instruction = CLASSIFY_AND_ACT_V14.body / V15.body (개인화 preamble·recent context 없음)
- finalizeAnalysis function-calling (mode=ANY), schema = _FINALIZE_PARAMS
- temperature=0.3, thinking_budget=0, model=gemini-3.1-flash-lite, max_output_tokens=1024
- user turn text = 프로덕션 _initial_user_text 의 image-only 형태(시간 컨텍스트 + 이미지 안내)
- **모델 입력은 이미지 1장 + 위 텍스트뿐. user_memo/url/파일명 한글 절대 미주입.**

실행:
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \
    python ../lab/active/usermemo-regression/bench.py
"""

from __future__ import annotations

import json
import mimetypes
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from google import genai
from google.genai import types

# mochi-backend 를 import 루트에 추가 (cwd 와 무관하게 동작).
_BACKEND = Path("/Users/jun/Downloads/mochi/mochi-backend")
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

# 프로덕션 모듈을 읽기 전용으로 import (수정하지 않는다).
from app.modules.agent.prompts.system_prompts import (
    CLASSIFY_AND_ACT_V14,
    CLASSIFY_AND_ACT_V15,
)
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE_PARAMS

HERE = Path(__file__).parent
IMAGE_DIR = Path("/Users/jun/Downloads/screenshot 2")
OUT_JSON = HERE / "results.json"
OUT_MD = HERE / "summary.md"

MODEL = "gemini-3.1-flash-lite"
LOCATION = os.getenv("GOOGLE_CLOUD_LOCATION", "global")
PROJECT = os.getenv("GOOGLE_CLOUD_PROJECT", "axial-device-460408-i9")
INTENT_TOKENS = {"schedule", "todo", "knowledge", "memo"}
KOREA_TZ = ZoneInfo("Asia/Seoul")
_FINALIZE = "finalizeAnalysis"


def korea_time_context() -> str:
    kst = datetime.now(KOREA_TZ)
    return (
        "# 시간 컨텍스트\n"
        f"현재 기준시각(Asia/Seoul): {kst.isoformat(timespec='seconds')}\n"
        "상대 날짜·요일·마감 표현은 이 한국 기준시각으로 해석하세요."
    )


def user_text() -> str:
    # 프로덕션 _initial_user_text 의 image-only 경로: 시간 컨텍스트 + 이미지 안내만.
    # (text/url/user_memo/recent_context 블록은 모두 없음.)
    return "\n\n".join(
        [korea_time_context(), "첨부된 스크린샷/이미지를 함께 분석하세요."]
    )


def parse_filename(name: str) -> tuple[list[str], str]:
    """`<gold_tokens>_<의도설명(한글)>.<ext>` → (gold_intents, user_intent_ko)."""
    stem = Path(name).stem
    # `(2)` 같은 suffix 무시
    stem = stem.split(" (")[0].strip()
    parts = stem.split("_")
    gold: list[str] = []
    idx = 0
    for idx, tok in enumerate(parts):
        if tok in INTENT_TOKENS:
            gold.append(tok)
        else:
            break
    else:
        idx = len(parts)
    user_intent = "_".join(parts[idx:]) if idx < len(parts) else ""
    return gold, user_intent


def build_decls() -> list[types.FunctionDeclaration]:
    # 프로덕션은 platformContext/webFetch 도 선언하지만, 이미지-only(URL 없음)라
    # 모델이 부를 일이 없다. finalize 만 선언해 함수콜이 항상 finalize 로 가게 한다.
    return [
        types.FunctionDeclaration(
            name=_FINALIZE,
            description="Emit the final structured analysis. Call exactly once when ready.",
            parameters=_FINALIZE_PARAMS,
        )
    ]


def extract_finalize(resp: Any) -> dict[str, Any] | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None) == _FINALIZE:
                return dict(fc.args or {})
    return None


def call(
    client: genai.Client,
    system_prompt: str,
    image_path: Path,
    decls: list[types.FunctionDeclaration],
) -> dict[str, Any]:
    mime = mimetypes.guess_type(image_path.name)[0] or "image/jpeg"
    img_part = types.Part.from_bytes(data=image_path.read_bytes(), mime_type=mime)
    contents = [
        types.Content(role="user", parts=[types.Part(text=user_text()), img_part])
    ]
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=1024,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        tools=[types.Tool(function_declarations=decls)],
        tool_config=types.ToolConfig(
            function_calling_config=types.FunctionCallingConfig(mode="ANY")
        ),
    )
    resp = client.models.generate_content(model=MODEL, contents=contents, config=cfg)
    payload = extract_finalize(resp)
    if payload is None:
        raise RuntimeError("no finalizeAnalysis function_call in response")
    return payload


def call_with_retry(
    client: genai.Client,
    system_prompt: str,
    image_path: Path,
    decls: list[types.FunctionDeclaration],
) -> dict[str, Any]:
    try:
        return call(client, system_prompt, image_path, decls)
    except Exception as exc:  # noqa: BLE001 — 재시도 1회
        time.sleep(2.0)
        try:
            return call(client, system_prompt, image_path, decls)
        except Exception as exc2:  # noqa: BLE001
            return {"_error": f"{type(exc2).__name__}: {exc2} (first: {exc})"}


def digest(raw: dict[str, Any]) -> dict[str, Any]:
    """raw finalize 출력에서 비교용 필드 추출 (raw 는 별도 보존)."""
    if "_error" in raw:
        return {"error": raw["_error"]}
    instances = raw.get("intent_instances") or []
    return {
        "summary": raw.get("summary"),
        "category": raw.get("category"),
        "intent_types": [str(i.get("intent_type")) for i in instances],
        "instances": [
            {
                "intent_type": i.get("intent_type"),
                "label": i.get("label"),
                "reasoning": i.get("reasoning"),
            }
            for i in instances
        ],
        "needs_review": raw.get("needs_review"),
    }


def main() -> int:
    files = sorted(
        p
        for p in IMAGE_DIR.iterdir()
        if p.suffix.lower() in {".png", ".jpg", ".jpeg"} and p.is_file()
    )
    print(f"found {len(files)} images in {IMAGE_DIR}", flush=True)

    client = genai.Client(vertexai=True, project=PROJECT, location=LOCATION)
    decls = build_decls()
    v14_body = CLASSIFY_AND_ACT_V14.body
    v15_body = CLASSIFY_AND_ACT_V15.body

    rows: list[dict[str, Any]] = []
    for n, path in enumerate(files, 1):
        gold, intent_ko = parse_filename(path.name)
        v14_raw = call_with_retry(client, v14_body, path, decls)
        v15_raw = call_with_retry(client, v15_body, path, decls)
        v14 = digest(v14_raw)
        v15 = digest(v15_raw)
        row = {
            "file": path.name,
            "gold_intents": gold,
            "user_intent_ko": intent_ko,
            "v14": v14,
            "v15": v15,
            "v14_raw": v14_raw,
            "v15_raw": v15_raw,
        }
        rows.append(row)
        print(
            f"[{n:02d}/{len(files)}] {path.name} gold={gold} "
            f"v14={v14.get('intent_types')} v15={v15.get('intent_types')} "
            f"v14_rev={v14.get('needs_review')} v15_rev={v15.get('needs_review')}",
            flush=True,
        )

    OUT_JSON.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    write_summary(rows)
    print(f"\nwrote {OUT_JSON}")
    print(f"wrote {OUT_MD}")
    return 0


def hit(pred: list[str], gold: list[str]) -> bool:
    return bool(set(pred) & set(gold))


def write_summary(rows: list[dict[str, Any]]) -> None:
    n = len(rows)
    v14_err = [r["file"] for r in rows if "error" in r["v14"]]
    v15_err = [r["file"] for r in rows if "error" in r["v15"]]
    scored = [r for r in rows if "error" not in r["v14"] and "error" not in r["v15"]]
    v14_hits = sum(1 for r in scored if hit(r["v14"]["intent_types"], r["gold_intents"]))
    v15_hits = sum(1 for r in scored if hit(r["v15"]["intent_types"], r["gold_intents"]))
    diffs = [
        r
        for r in scored
        if set(r["v14"]["intent_types"]) != set(r["v15"]["intent_types"])
    ]

    lines = [
        "# user_memo regression — image-only V14 vs V15",
        "",
        f"- model: `{MODEL}` / location: `{LOCATION}` / temperature 0.3 / thinking_budget 0",
        "- input policy: image only; no user_memo / no url / no filename / no recent context",
        f"- images: {n}",
        f"- errors: V14={len(v14_err)} {v14_err} / V15={len(v15_err)} {v15_err}",
        "",
        "## Intent hit (pred intent_types ∩ gold_intents ≠ ∅)",
        "",
        f"- V14: {v14_hits}/{len(scored)} = {round(v14_hits / len(scored), 4) if scored else 'n/a'}",
        f"- V15: {v15_hits}/{len(scored)} = {round(v15_hits / len(scored), 4) if scored else 'n/a'}",
        "",
        f"## intent_types diff (V14 ↔ V15): {len(diffs)} images",
        "",
    ]
    for r in diffs:
        lines.append(
            f"- `{r['file']}` gold={r['gold_intents']}: "
            f"V14={r['v14']['intent_types']} → V15={r['v15']['intent_types']}"
        )
    lines.append("")
    lines.append("## Per case")
    lines.append("")
    for r in rows:
        v14, v15 = r["v14"], r["v15"]
        lines.append(
            f"- `{r['file']}` gold={r['gold_intents']} | "
            f"V14 intents={v14.get('intent_types', v14.get('error'))} review={v14.get('needs_review')} cat={v14.get('category')} | "
            f"V15 intents={v15.get('intent_types', v15.get('error'))} review={v15.get('needs_review')} cat={v15.get('category')}"
        )
    OUT_MD.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
