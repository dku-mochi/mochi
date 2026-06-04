#!/usr/bin/env python3
"""Run current intent_instances + review_options prompt on user-provided validation images.

Uses image + filename memo as input because the provided filenames encode the
user's saved intent.
"""

from __future__ import annotations

import json
import mimetypes
import os
import time
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types

HERE = Path(__file__).parent
DATA_DIR = HERE.parent.parent / "data" / "intent-validation"
MANIFEST = HERE / "validation_manifest.json"
OUT_JSON = HERE / "validation_user_memo_results.json"
OUT_MD = HERE / "validation_user_memo_report.md"
MODEL = os.getenv("GEMINI_MODEL", "gemini-3.1-flash-lite")
LOCATION = os.getenv("GOOGLE_CLOUD_LOCATION", "global")
INTENTS = ["schedule", "todo", "knowledge", "memo"]

PAYLOAD_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "nullable": True},
        "date": {"type": "string", "nullable": True},
        "time": {"type": "string", "nullable": True},
        "deadline": {"type": "string", "nullable": True},
        "person": {"type": "string", "nullable": True},
        "topic": {"type": "string", "nullable": True},
        "url": {"type": "string", "nullable": True},
        "note": {"type": "string", "nullable": True},
    },
}

SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "needs_review": {"type": "boolean"},
        "intent_instances": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "intent_type": {"type": "string", "enum": INTENTS},
                    "label": {"type": "string"},
                    "payload": PAYLOAD_SCHEMA,
                    "reasoning": {"type": "string"},
                },
                "required": ["intent_type", "label", "payload", "reasoning"],
            },
        },
        "review_options": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "intent_type": {"type": "string", "enum": INTENTS},
                    "label": {"type": "string"},
                    "reasoning": {"type": "string"},
                },
                "required": ["intent_type", "label", "reasoning"],
            },
        },
    },
    "required": ["summary", "needs_review", "intent_instances", "review_options"],
}

PROMPT = """\
MOCHI intent schema validation.

Analyze the screenshot as a record the user saved to MOCHI. The user memo is a strong signal of intent.
Return only instances that MOCHI should save now. Do not include rejected or merely possible candidates in intent_instances.
All output text must be Korean.

Use these 4 intent types:
- schedule: a specific time-bound event, appointment, meeting, flight, performance, deadline, travel schedule, or submission/application period.
- todo: a concrete action the user should do, such as apply, submit, use coupon/gifticon, buy later, visit later, check, reserve, or attend.
- knowledge: durable reference or learning/travel/real-estate/news/product information.
- memo: entertainment, emotional/casual record, or safe fallback.

Fields:
- intent_instances: saved/materialized instances only. If an instance is in this array, it is applicable by definition.
- needs_review: true only when asking is clearly necessary. Most screenshots are saved without explicit user intent; that alone is not enough to ask.
- review_options: choices to show only when needs_review=true. These are not saved until the user chooses. Use [] when needs_review=false.

Decision rules:
- Default to needs_review=false. Choose the safest useful saved intent instead of asking.
- Always output at least one intent_instance. Even when needs_review=true, save a safe memo fallback.
- Prefer one intent_instance per screenshot. Add multiple instances only when there are clearly separate user-relevant execution units, such as one schedule/deadline plus one concrete action.
- User memo dominates: if the memo says later buy/apply/use/visit/check, create todo. If it names schedule/flight/performance/date/place, create schedule when time/place information is visible.
- For course/application/submission/recruiting/deadline screens, use schedule + todo when both period/deadline and action are visible.
- For flight/performance/schedule screens, use schedule. Add todo only if the memo clearly says to do an action beyond attending/checking.
- For travel information, real-estate information, product information, or news, save knowledge unless the memo says to buy/visit/use/apply.
- For Netflix/interesting entertainment, save memo.
- For product screenshots with memo '나중에 살', save todo with product payload and needs_review=false.
- Do not add review_options unless needs_review=true.

Payload:
- Allowed fields are title, date, time, deadline, person, topic, url, note.
- Fill useful typed fields visible or strongly implied by the screenshot and memo. Leave unknown fields null or omit them. Do not invent dates.
"""


def call(client: genai.Client, image_path: Path, memo: str) -> tuple[dict[str, Any], float]:
    mime = mimetypes.guess_type(image_path.name)[0] or "image/jpeg"
    part = types.Part.from_bytes(data=image_path.read_bytes(), mime_type=mime)
    config = types.GenerateContentConfig(
        system_instruction=PROMPT,
        temperature=0.0,
        max_output_tokens=2048,
        response_mime_type="application/json",
        response_schema=SCHEMA,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    started = time.perf_counter()
    resp = client.models.generate_content(
        model=MODEL,
        contents=[part, f"사용자 메모: {memo}\n이 저장 기록을 분석해줘."],
        config=config,
    )
    return json.loads(resp.text), (time.perf_counter() - started) * 1000


def main() -> int:
    items = json.loads(MANIFEST.read_text())["items"]
    client = genai.Client(vertexai=True, location=LOCATION)
    rows = []
    for item in items:
        path = DATA_DIR / item["file"]
        parsed, latency_ms = call(client, path, item["memo"])
        row = {
            **item,
            "prediction": parsed,
            "latency_ms": round(latency_ms, 1),
        }
        rows.append(row)
        print(
            f"[{item['index']:02d}/{len(items)}] {item['memo']} -> "
            f"{[i.get('intent_type') for i in parsed.get('intent_instances', [])]} "
            f"review={parsed.get('needs_review')} summary={parsed.get('summary')}",
            flush=True,
        )
    OUT_JSON.write_text(json.dumps({"model": MODEL, "rows": rows}, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = [
        "# Validation user memo eval",
        "",
        f"- model: `{MODEL}`",
        f"- items: {len(rows)}",
        "",
        "## Results",
        "",
    ]
    for row in rows:
        pred = row["prediction"]
        lines.append(
            f"- `{row['memo']}`: intents={[i.get('intent_type') for i in pred.get('intent_instances', [])]}, "
            f"review={pred.get('needs_review')}, options={len(pred.get('review_options', []))}, "
            f"summary={pred.get('summary')}"
        )
    OUT_MD.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT_JSON}")
    print(f"wrote {OUT_MD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
