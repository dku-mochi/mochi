#!/usr/bin/env python3
"""Evaluate intent_instances + review_options on labeled local images."""

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
DATA_DIR = HERE.parent.parent / "data" / "gcs-captures"
LABELS_JSON = HERE / "gcs_image_human_labels.json"
OUT_JSON = HERE / "image_instances_review_options_eval_results.json"
OUT_MD = HERE / "image_instances_review_options_eval_report.md"
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
MOCHI intent schema experiment.

Analyze the screenshot as a record the user saved to MOCHI.
Return only instances that MOCHI should save now. Do not include rejected or merely possible candidates in intent_instances.
All output text must be Korean.

Use these 4 intent types:
- schedule: a specific time-bound event, appointment, meeting, or deadline. A year/date mentioned inside reference/news/ad content is not schedule by itself.
- todo: a concrete action the user should do. Buying, reserving, commenting, applying, replying, or checking something can be todo only when the user intent is safe enough.
- knowledge: durable reference or learning value, including technical/product/news information.
- memo: emotional, atmospheric, one-off memory, entertainment, or safe fallback.

Fields:
- intent_instances: saved/materialized instances only. If an instance is in this array, it is applicable by definition.
- needs_review: true only when asking is clearly necessary. Most screenshots are saved without explicit user intent; that alone is not enough to ask.
- review_options: choices to show only when needs_review=true. These are not saved until the user chooses. Use [] when needs_review=false.

Decision rules:
- Default to needs_review=false. Choose the safest useful saved intent instead of asking.
- Always output at least one intent_instance. Even when needs_review=true, save a safe memo fallback.
- Prefer one intent_instance per screenshot. Add multiple instances only when there are clearly separate user-relevant execution units, such as one appointment plus one concrete action, or several explicit todo items.
- Do not output duplicate intent_types unless the screenshot clearly contains multiple separate todo/schedule execution units. Collapse multiple knowledge topics into one knowledge instance.
- Ignore incidental ads, recommendations, adjacent feed cards, and unrelated secondary content. Classify the main saved post/screen, not every visible item.
- Set needs_review=true only for genuine ambiguity: the screenshot itself asks the user to choose a classification, says it is confused, shows an unresolved either/or decision, or has too little content to form even a safe memo/knowledge item.
- Do not set needs_review=true merely because the screenshot is a product, restaurant, ad, news, social post, YouTube video, or public information page.
- For product/ad/restaurant posts, save memo by default. Add todo only when there is a concrete user action beyond a generic app button, such as "comment to receive file", "submit application", "book inspection", or "upload documents".
- Generic social buttons like follow, like, share, save, "reserve now", "buy now", or shopping-cart UI are not enough to create todo by themselves.
- For technical/news/article/video content, save knowledge by default if it contains durable information, tips, explanation, product specs, or a GitHub/link/reference. Entertainment, jokes, food clips, emotional content, and casual reels are memo.
- Do not add schedule just because a date appears in news, article, ad, sale period, or caption. Schedule requires user-specific event/deadline/reminder.
- For contest, application, inspection, appointment, submission, or official deadline screens, use schedule + todo when both a deadline/period and an action are visible.
- If a post says "like/comment to receive a file or guide", save knowledge plus todo and needs_review=false. The action is clear enough.
- Same intent_type may appear multiple times when there are multiple execution units.

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


def payload_quality(instances: list[dict[str, Any]]) -> float:
    if not instances:
        return 0.0
    ok = 0
    for inst in instances:
        payload = inst.get("payload")
        if isinstance(payload, dict) and any(v not in (None, "", [], {}) for v in payload.values()):
            ok += 1
    return ok / len(instances)


def call(client: genai.Client, image_path: Path) -> tuple[dict[str, Any], float]:
    mime = mimetypes.guess_type(image_path.name)[0] or "image/jpeg"
    config = types.GenerateContentConfig(
        system_instruction=PROMPT,
        temperature=0.0,
        max_output_tokens=2048,
        response_mime_type="application/json",
        response_schema=SCHEMA,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    part = types.Part.from_bytes(data=image_path.read_bytes(), mime_type=mime)
    start = time.perf_counter()
    resp = client.models.generate_content(
        model=MODEL,
        contents=[part, "Analyze this saved screenshot for MOCHI."],
        config=config,
    )
    return json.loads(resp.text), (time.perf_counter() - start) * 1000


def main() -> int:
    labels = json.loads(LABELS_JSON.read_text())["items"]
    eval_items = [item for item in labels if item["eval_use"] == "include"]
    client = genai.Client(vertexai=True, location=LOCATION)
    rows = []
    for idx, item in enumerate(eval_items, 1):
        path = DATA_DIR / item["file"]
        parsed, latency_ms = call(client, path)
        pred = [it.get("intent_type") for it in parsed.get("intent_instances", [])]
        gold = [it["intent_type"] for it in item["intent_instances"]]
        review_pred = bool(parsed.get("needs_review"))
        review_gold = bool(item["needs_review"])
        options = parsed.get("review_options", [])
        metrics = {
            "intent_f1": round(f1_multiset([str(x) for x in pred], gold), 4),
            "count_exact": len(pred) == len(gold),
            "review_correct": review_pred == review_gold,
            "review_options_shape_ok": (bool(options) if review_pred else not bool(options)),
            "payload_quality": round(payload_quality(parsed.get("intent_instances", [])), 4),
        }
        row = {
            "index": item["index"],
            "file": item["file"],
            "gold": {
                "intents": gold,
                "needs_review": review_gold,
                "review_options": item["review_options"],
                "summary": item["visible_summary"],
            },
            "prediction": parsed,
            "metrics": metrics,
            "latency_ms": round(latency_ms, 1),
        }
        rows.append(row)
        print(
            f"[{idx:02d}/{len(eval_items)}] {item['file']} "
            f"gold={gold}/{review_gold} pred={pred}/{review_pred} "
            f"f1={metrics['intent_f1']} review_ok={metrics['review_correct']}",
            flush=True,
        )

    summary = {
        "model": MODEL,
        "location": LOCATION,
        "n": len(rows),
        "mean_intent_f1": round(statistics.mean(r["metrics"]["intent_f1"] for r in rows), 4),
        "count_accuracy": round(statistics.mean(r["metrics"]["count_exact"] for r in rows), 4),
        "review_accuracy": round(statistics.mean(r["metrics"]["review_correct"] for r in rows), 4),
        "review_options_shape_accuracy": round(statistics.mean(r["metrics"]["review_options_shape_ok"] for r in rows), 4),
        "payload_quality": round(statistics.mean(r["metrics"]["payload_quality"] for r in rows), 4),
        "mean_latency_ms": round(statistics.mean(r["latency_ms"] for r in rows), 1),
        "rows": rows,
    }
    OUT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "# Image intent_instances + review_options eval",
        "",
        f"- model: `{MODEL}`",
        f"- images: {summary['n']}",
        f"- mean intent F1: {summary['mean_intent_f1']}",
        f"- count accuracy: {summary['count_accuracy']}",
        f"- review accuracy: {summary['review_accuracy']}",
        f"- review_options shape accuracy: {summary['review_options_shape_accuracy']}",
        f"- payload quality: {summary['payload_quality']}",
        "",
        "## Failures / Drift",
        "",
    ]
    for row in rows:
        m = row["metrics"]
        if m["intent_f1"] < 1 or not m["count_exact"] or not m["review_correct"] or not m["review_options_shape_ok"]:
            pred = row["prediction"]
            lines.append(
                f"- `{row['file']}` gold={row['gold']['intents']}/{row['gold']['needs_review']} "
                f"pred={[it.get('intent_type') for it in pred.get('intent_instances', [])]}/{pred.get('needs_review')} "
                f"f1={m['intent_f1']} count={m['count_exact']} review={m['review_correct']} "
                f"options_shape={m['review_options_shape_ok']} — {pred.get('summary', '')}"
            )
    lines.append("")
    lines.append("## Per Case")
    lines.append("")
    for row in rows:
        pred = row["prediction"]
        lines.append(
            f"- `{row['file']}`: pred={[it.get('intent_type') for it in pred.get('intent_instances', [])]}, "
            f"review={pred.get('needs_review')}, options={len(pred.get('review_options', []))}, "
            f"summary={pred.get('summary', '')}"
        )
    OUT_MD.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT_JSON}")
    print(f"wrote {OUT_MD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
