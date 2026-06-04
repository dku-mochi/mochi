#!/usr/bin/env python3
"""Inventory downloaded GCS capture images for intent schema experiments.

The script does not mutate production data. It reads local files under
lab/data/gcs-captures/, asks Gemini Vision for a compact suitability assessment,
and writes gcs_image_inventory.json / .md in this lab directory.
"""

from __future__ import annotations

import json
import mimetypes
import os
import statistics
import time
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types


HERE = Path(__file__).parent
SAMPLE_DIR = HERE.parent.parent / "data" / "gcs-captures"
OUT_JSON = HERE / "gcs_image_inventory.json"
OUT_MD = HERE / "gcs_image_inventory.md"
MODEL = os.getenv("GEMINI_MODEL", "gemini-3.1-flash-lite")
LOCATION = os.getenv("GOOGLE_CLOUD_LOCATION", "global")

SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "visible_summary": {"type": "string"},
        "content_category": {
            "type": "string",
            "enum": [
                "product",
                "article_or_learning",
                "calendar_or_event",
                "chat_or_social",
                "map_or_place",
                "media",
                "finance_or_document",
                "unknown",
            ],
        },
        "expected_intents": {
            "type": "array",
            "items": {"type": "string", "enum": ["schedule", "todo", "knowledge", "memo"]},
        },
        "needs_review_likely": {"type": "boolean"},
        "review_reason": {"type": "string"},
        "schema_stressors": {
            "type": "array",
            "items": {
                "type": "string",
                "enum": [
                    "multi_instance",
                    "multi_intent",
                    "ambiguous_user_intent",
                    "date_not_schedule",
                    "deadline",
                    "low_context",
                    "payload_extraction",
                    "review_options",
                ],
            },
        },
        "sensitivity": {
            "type": "string",
            "enum": ["low", "medium", "high"],
        },
        "sensitivity_reason": {"type": "string"},
        "suitability": {"type": "integer"},
        "exclude_reason": {"type": "string"},
    },
    "required": [
        "visible_summary",
        "content_category",
        "expected_intents",
        "needs_review_likely",
        "review_reason",
        "schema_stressors",
        "sensitivity",
        "sensitivity_reason",
        "suitability",
        "exclude_reason",
    ],
}

PROMPT = """\
You are selecting screenshots for MOCHI intent schema experiments.

Assess whether this image is useful for testing:
- intent_instances: saved intent instances only
- needs_review: whether to ask the user
- review_options: choices when the user must decide
- payload extraction: title/date/time/deadline/person/topic/url/note

Return Korean text in summaries/reasons.

Suitability scale:
5 = excellent schema stress case (multi intent, ambiguity, deadline, payload extraction, or review options)
4 = useful single/multi intent case with clear visual evidence
3 = usable but ordinary
2 = weak or low context
1 = exclude from shared eval

Sensitivity:
high = private messages, personal identity, financial/medical/legal document, credentials, exact address, phone/email
medium = social profile, shopping/order details, private preference, partial personal data
low = public product/article/media/event content
"""


def image_files() -> list[Path]:
    return sorted(
        p for p in SAMPLE_DIR.iterdir()
        if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )


def analyze(client: genai.Client, path: Path) -> dict[str, Any]:
    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    config = types.GenerateContentConfig(
        system_instruction=PROMPT,
        temperature=0.0,
        max_output_tokens=1024,
        response_mime_type="application/json",
        response_schema=SCHEMA,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    part = types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)
    started = time.perf_counter()
    response = client.models.generate_content(
        model=MODEL,
        contents=[part, "Analyze this screenshot for schema experiment suitability."],
        config=config,
    )
    parsed = json.loads(response.text)
    parsed["file"] = path.name
    parsed["bytes"] = path.stat().st_size
    parsed["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return parsed


def write_report(rows: list[dict[str, Any]]) -> None:
    usable = [r for r in rows if r["suitability"] >= 3 and r["sensitivity"] != "high"]
    best = sorted(usable, key=lambda r: (-r["suitability"], r["sensitivity"], r["file"]))
    by_category: dict[str, int] = {}
    by_sensitivity: dict[str, int] = {}
    by_stressor: dict[str, int] = {}
    for row in rows:
        by_category[row["content_category"]] = by_category.get(row["content_category"], 0) + 1
        by_sensitivity[row["sensitivity"]] = by_sensitivity.get(row["sensitivity"], 0) + 1
        for stressor in row["schema_stressors"]:
            by_stressor[stressor] = by_stressor.get(stressor, 0) + 1

    lines = [
        "# GCS image inventory",
        "",
        f"- model: `{MODEL}`",
        f"- images analyzed: {len(rows)}",
        f"- usable for lab eval (suitability >= 3 and not high sensitivity): {len(usable)}",
        f"- mean suitability: {statistics.mean(r['suitability'] for r in rows):.2f}",
        "",
        "## Distribution",
        "",
        f"- by category: `{json.dumps(by_category, ensure_ascii=False, sort_keys=True)}`",
        f"- by sensitivity: `{json.dumps(by_sensitivity, ensure_ascii=False, sort_keys=True)}`",
        f"- by stressor: `{json.dumps(by_stressor, ensure_ascii=False, sort_keys=True)}`",
        "",
        "## Best candidates",
        "",
    ]
    for row in best[:20]:
        lines.append(
            f"- `{row['file']}` score={row['suitability']} sensitivity={row['sensitivity']} "
            f"category={row['content_category']} intents={row['expected_intents']} "
            f"review={row['needs_review_likely']} stressors={row['schema_stressors']} — "
            f"{row['visible_summary']}"
        )
    lines.append("")
    lines.append("## Exclusions / caution")
    lines.append("")
    for row in rows:
        if row["suitability"] < 3 or row["sensitivity"] == "high":
            lines.append(
                f"- `{row['file']}` score={row['suitability']} sensitivity={row['sensitivity']} — "
                f"{row['exclude_reason'] or row['sensitivity_reason']}"
            )
    OUT_MD.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    files = image_files()
    if not files:
        raise SystemExit(f"no images under {SAMPLE_DIR}")
    client = genai.Client(vertexai=True, location=LOCATION)
    rows = []
    for idx, path in enumerate(files, 1):
        row = analyze(client, path)
        rows.append(row)
        print(
            f"[{idx:02d}/{len(files)}] {path.name} score={row['suitability']} "
            f"sens={row['sensitivity']} cat={row['content_category']} "
            f"intents={','.join(row['expected_intents'])}",
            flush=True,
        )
    OUT_JSON.write_text(json.dumps({"model": MODEL, "rows": rows}, ensure_ascii=False, indent=2), encoding="utf-8")
    write_report(rows)
    print(f"wrote {OUT_JSON}")
    print(f"wrote {OUT_MD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
