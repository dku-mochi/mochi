#!/usr/bin/env python3
"""Run intent_instances + review_options validation on user images without filename memo.

The manifest filenames/memos are used only as offline gold labels for scoring.
The model receives the image bytes and a generic instruction only.
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
DATA_DIR = HERE.parent.parent / "data" / "intent-validation"
MANIFEST = HERE / "validation_manifest.json"
OUT_JSON = HERE / "validation_image_only_results.json"
OUT_MD = HERE / "validation_image_only_report.md"
MODEL = os.getenv("GEMINI_MODEL", "gemini-3.1-flash-lite")
LOCATION = os.getenv("GOOGLE_CLOUD_LOCATION", "global")
INTENTS = ["schedule", "todo", "knowledge", "memo"]

GOLD_INTENTS: dict[int, list[str]] = {
    1: ["schedule"],
    2: ["schedule", "todo"],
    3: ["schedule", "todo"],
    4: ["schedule", "todo"],
    5: ["todo"],
    6: ["knowledge"],
    7: ["knowledge"],
    8: ["knowledge"],
    9: ["schedule"],
    10: ["schedule"],
    11: ["knowledge"],
    12: ["memo"],
    13: ["todo"],
    14: ["todo"],
    15: ["todo"],
}

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

Analyze the screenshot as a record the user saved to MOCHI.
Return only instances that MOCHI should save now. Do not include rejected or merely possible candidates in intent_instances.
All output text must be Korean.

Use these 4 intent types:
- schedule: a specific time-bound event, appointment, meeting, performance, flight, deadline, travel schedule, or submission/application period.
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
- For course/application/submission/recruiting/deadline screens, use schedule + todo when both period/deadline and action are visible.
- For flight/performance/schedule screens, use schedule. Add todo only if a concrete user action is visible beyond simply knowing the schedule.
- For coupons/gifticons/vouchers, use todo if the screen shows a usable benefit, expiry, barcode, or redemption context.
- For limited-time brand discount/store events, use schedule + todo when the period/benefit is visible, because the saved utility is normally to use or visit during the event.
- For travel tips, location guides, itinerary advice, country/city logistics, real-estate listings, or news/reference information, save knowledge even when the content is shown in a reel/video/chat UI.
- For entertainment/media recommendations such as Netflix titles, movies, dramas, books, podcasts, or casual viewing ideas, save memo by default unless the screen is clearly a study/reference note.
- For product screenshots with a specific buyable item, product recommendation, or shopping/product detail context, save todo by default. Use knowledge only for comparison/spec/reference content where no later purchase/use action is suggested by the screen.
- If a schedule/inspection/deadline is the main saved utility, do not add knowledge merely because surrounding 안내 text is visible.
- Do not add review_options unless needs_review=true.

Payload:
- Allowed fields are title, date, time, deadline, person, topic, url, note.
- Fill useful typed fields visible or strongly implied by the screenshot. Leave unknown fields null or omit them. Do not invent dates.
"""


def counts(values: list[str]) -> dict[str, int]:
    out: dict[str, int] = {}
    for value in values:
        out[value] = out.get(value, 0) + 1
    return out


def f1_multiset(pred: list[str], gold: list[str]) -> float:
    pc, gc = counts(pred), counts(gold)
    overlap = sum(min(pc.get(k, 0), gc.get(k, 0)) for k in set(pc) | set(gc))
    if not pred and not gold:
        return 1.0
    if not pred or not gold:
        return 0.0
    precision = overlap / len(pred)
    recall = overlap / len(gold)
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def call(client: genai.Client, image_path: Path) -> tuple[dict[str, Any], float]:
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
        contents=[part, "Analyze this saved screenshot for MOCHI."],
        config=config,
    )
    return json.loads(resp.text), (time.perf_counter() - started) * 1000


def main() -> int:
    items = json.loads(MANIFEST.read_text())["items"]
    client = genai.Client(vertexai=True, location=LOCATION)
    rows = []
    for item in items:
        path = DATA_DIR / item["file"]
        parsed, latency_ms = call(client, path)
        pred = [str(inst.get("intent_type")) for inst in parsed.get("intent_instances", [])]
        gold = GOLD_INTENTS[item["index"]]
        metrics = {
            "intent_f1": round(f1_multiset(pred, gold), 4),
            "count_exact": len(pred) == len(gold),
            "review_correct": parsed.get("needs_review") is False,
            "review_options_shape_ok": not bool(parsed.get("review_options")),
        }
        row = {
            "index": item["index"],
            "file": item["file"],
            "gold_intents": gold,
            "prediction": parsed,
            "metrics": metrics,
            "latency_ms": round(latency_ms, 1),
        }
        rows.append(row)
        print(
            f"[{item['index']:02d}/{len(items)}] gold={gold} pred={pred} "
            f"review={parsed.get('needs_review')} f1={metrics['intent_f1']} "
            f"summary={parsed.get('summary')}",
            flush=True,
        )

    summary = {
        "model": MODEL,
        "location": LOCATION,
        "n": len(rows),
        "input_policy": "image_only_no_filename_no_user_memo",
        "mean_intent_f1": round(statistics.mean(row["metrics"]["intent_f1"] for row in rows), 4),
        "count_accuracy": round(statistics.mean(row["metrics"]["count_exact"] for row in rows), 4),
        "review_accuracy": round(statistics.mean(row["metrics"]["review_correct"] for row in rows), 4),
        "review_options_shape_accuracy": round(
            statistics.mean(row["metrics"]["review_options_shape_ok"] for row in rows), 4
        ),
        "mean_latency_ms": round(statistics.mean(row["latency_ms"] for row in rows), 1),
        "rows": rows,
    }
    OUT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "# Validation image-only eval",
        "",
        f"- model: `{MODEL}`",
        "- input policy: image only; no filename; no user memo",
        f"- items: {summary['n']}",
        f"- mean intent F1: {summary['mean_intent_f1']}",
        f"- count accuracy: {summary['count_accuracy']}",
        f"- review accuracy: {summary['review_accuracy']}",
        f"- review_options shape accuracy: {summary['review_options_shape_accuracy']}",
        "",
        "## Failures / Drift",
        "",
    ]
    for row in rows:
        pred = row["prediction"]
        pred_intents = [inst.get("intent_type") for inst in pred.get("intent_instances", [])]
        if (
            row["metrics"]["intent_f1"] < 1
            or not row["metrics"]["count_exact"]
            or not row["metrics"]["review_correct"]
            or not row["metrics"]["review_options_shape_ok"]
        ):
            lines.append(
                f"- `{row['file']}` gold={row['gold_intents']} pred={pred_intents} "
                f"review={pred.get('needs_review')} f1={row['metrics']['intent_f1']} "
                f"count={row['metrics']['count_exact']} — {pred.get('summary', '')}"
            )
    lines.append("")
    lines.append("## Per Case")
    lines.append("")
    for row in rows:
        pred = row["prediction"]
        lines.append(
            f"- `{row['file']}`: gold={row['gold_intents']}, "
            f"pred={[inst.get('intent_type') for inst in pred.get('intent_instances', [])]}, "
            f"review={pred.get('needs_review')}, options={len(pred.get('review_options', []))}, "
            f"summary={pred.get('summary', '')}"
        )
    OUT_MD.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT_JSON}")
    print(f"wrote {OUT_MD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
