#!/usr/bin/env python3
"""Intent schema decision bench.

Compares three candidate output schemas for the 0009 intent migration target:

A. score_flat: current document target. LLM emits candidates with applicability
   scores; server derives active intents and needs_review by thresholds.
B. boolean_instances: PR #6 target. LLM emits intent_instances with applicable
   booleans and top-level needs_review.
C. boolean_instances_debug: same decision surface as B, but keeps a non-decision
   evidence_score for evaluation/debugging.
D. boolean_instances_refined: same storage shape as B, with stricter decision
   rules for vague "later", learning, long-term goals, and date-like text.
E. instances_review_options: removes applicable. intent_instances contains only
   instances to save; review_options contains possible user choices when review
   is needed.

Run:
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
    uv run --directory mochi-backend \
    python ../lab/active/intent-schema-decision/intent_schema_decision_bench.py
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types


HERE = Path(__file__).parent
RESULTS_JSON = HERE / "intent_schema_decision_results.json"
REPORT_MD = HERE / "intent_schema_decision_report.md"

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


@dataclass(frozen=True)
class Case:
    id: str
    input: str
    gold_active: tuple[str, ...]
    gold_instance_count: int
    gold_needs_review: bool
    note: str


CASES: list[Case] = [
    Case("single_schedule", "오늘 저녁 7시 성수에서 민지랑 약속", ("schedule",), 1, False, "명확한 일정"),
    Case("single_todo", "지원이 답장해야 함. 오늘 안에", ("todo",), 1, False, "명확한 행동"),
    Case("single_knowledge", "ReAct 에이전트 구조 나중에 공부", ("knowledge",), 1, False, "학습/참조"),
    Case("single_memo", "노을 너무 예뻤다. 그냥 기록", ("memo",), 1, False, "정서 기록"),
    Case(
        "schedule_todo",
        "금요일 3시 디자인 리뷰. 그 전까지 시안 2개 준비",
        ("schedule", "todo"),
        2,
        False,
        "일정 + 준비 할 일",
    ),
    Case(
        "todo_knowledge",
        "마우스 살까 말까 고민. 로지텍 MX Master 3S랑 Keychron M6 비교해보기",
        ("todo", "knowledge"),
        2,
        False,
        "구매 행동 + 비교 정보",
    ),
    Case(
        "same_type_multi_todo",
        "회의록: 1) 찬서에게 API 명세 공유 2) 세현이는 eval dataset 만들기 3) 금요일 2시 중간 점검",
        ("todo", "todo", "schedule"),
        3,
        False,
        "같은 todo type 다중 instance + 일정",
    ),
    Case(
        "same_type_multi_schedule",
        "다음 주 일정: 월 9시 발표, 수 3시 디자인 리뷰, 금 6시 회식",
        ("schedule", "schedule", "schedule"),
        3,
        False,
        "같은 schedule type 다중 instance",
    ),
    Case(
        "ambiguous_product",
        "이 가방 예쁘긴 한데 살지 말지 모르겠다",
        ("todo", "memo"),
        2,
        True,
        "구매 고민과 감상 사이, 물어보는 게 유리",
    ),
    Case(
        "ambiguous_low_signal",
        "이거 나중에",
        ("memo",),
        1,
        True,
        "정보 부족, 보존 + 확인",
    ),
    Case(
        "date_not_schedule",
        "2026년 연말정산 공제 항목 정리 글",
        ("knowledge",),
        1,
        False,
        "날짜가 있어도 사건 일정 아님",
    ),
    Case(
        "deadline_todo",
        "장학금 신청 6월 20일 18시 마감. 서류 업로드해야 함",
        ("todo", "schedule"),
        2,
        False,
        "마감 있는 todo는 일정성도 있음",
    ),
    Case(
        "link_knowledge_todo",
        "https://example.com/fastapi-clean-architecture 나중에 읽고 프로젝트에 적용해보기",
        ("knowledge", "todo"),
        2,
        False,
        "읽을 자료 + 적용 행동",
    ),
    Case(
        "memo_and_todo",
        "카페 분위기 좋았다. 다음에 지수 데려가기",
        ("memo", "todo"),
        2,
        False,
        "감상 기록 + 다음 행동",
    ),
    Case(
        "uncertain_two_options",
        "이 사람 연락처 저장? 아니면 그냥 대화 기록용?",
        ("todo", "memo"),
        2,
        True,
        "사용자가 직접 모호성을 표현",
    ),
    Case(
        "knowledge_no_action",
        "Postgres GIN index는 jsonb containment 쿼리에 유용",
        ("knowledge",),
        1,
        False,
        "순수 지식"),
    Case(
        "todo_goal",
        "올해 안에 토익 900 만들기",
        ("todo",),
        1,
        False,
        "장기 목표도 todo",
    ),
    Case(
        "memo_low_review_false",
        "오늘 점심 진짜 맛있었다",
        ("memo",),
        1,
        False,
        "명확한 memo는 review 불필요",
    ),
]


SCHEMAS: dict[str, dict[str, Any]] = {
    "score_flat": {
        "type": "object",
        "properties": {
            "summary": {"type": "string"},
            "intents": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "intent": {"type": "string", "enum": INTENTS},
                        "applicability": {"type": "number"},
                        "label": {"type": "string"},
                        "reasoning": {"type": "string"},
                    },
                    "required": ["intent", "applicability", "label", "reasoning"],
                },
            },
        },
        "required": ["summary", "intents"],
    },
    "boolean_instances": {
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
                        "applicable": {"type": "boolean"},
                        "label": {"type": "string"},
                        "payload": PAYLOAD_SCHEMA,
                        "reasoning": {"type": "string"},
                    },
                    "required": ["intent_type", "applicable", "label", "payload", "reasoning"],
                },
            },
        },
        "required": ["summary", "needs_review", "intent_instances"],
    },
    "boolean_instances_debug": {
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
                        "applicable": {"type": "boolean"},
                        "evidence_score": {"type": "number"},
                        "label": {"type": "string"},
                        "payload": PAYLOAD_SCHEMA,
                        "reasoning": {"type": "string"},
                    },
                    "required": [
                        "intent_type",
                        "applicable",
                        "evidence_score",
                        "label",
                        "payload",
                        "reasoning",
                    ],
                },
            },
        },
        "required": ["summary", "needs_review", "intent_instances"],
    },
    "boolean_instances_refined": {
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
                        "applicable": {"type": "boolean"},
                        "label": {"type": "string"},
                        "payload": PAYLOAD_SCHEMA,
                        "reasoning": {"type": "string"},
                    },
                    "required": ["intent_type", "applicable", "label", "payload", "reasoning"],
                },
            },
        },
        "required": ["summary", "needs_review", "intent_instances"],
    },
    "instances_review_options": {
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
    },
}


PROMPTS: dict[str, str] = {
    "score_flat": """\
MOCHI intent schema experiment.

Return a flat list of plausible user intents for this saved record.
Use these 4 intent types:
- schedule: a time-bound event or deadline.
- todo: an action the user should do.
- knowledge: durable reference or learning value.
- memo: emotional, atmospheric, one-off memory, or safe fallback.

Each intent has an independent applicability score from 0.0 to 1.0.
Scores do not need to sum to 1.0. Multiple intents can be high.
Do not output primary/secondary hierarchy.
""",
    "boolean_instances": """\
MOCHI intent schema experiment.

Return intent_instances for this saved record.
Use these 4 intent types:
- schedule: a time-bound event or deadline.
- todo: an action the user should do.
- knowledge: durable reference or learning value.
- memo: emotional, atmospheric, one-off memory, or safe fallback.

For each instance:
- applicable means "MOCHI should save/materialize this instance".
- payload should contain only useful typed fields visible or strongly implied by the input.
  Allowed payload fields are title, date, time, deadline, person, topic, url, note.
  Leave unknown fields null or omit them. Do not invent dates.

Top-level needs_review means "MOCHI should passively ask the user because the intent decision is under-specified or user-only".
If no instance is applicable, include a memo fallback instance.
Same intent_type may appear multiple times when there are multiple execution units.
""",
    "boolean_instances_debug": """\
MOCHI intent schema experiment.

Return intent_instances for this saved record.
Use these 4 intent types:
- schedule: a time-bound event or deadline.
- todo: an action the user should do.
- knowledge: durable reference or learning value.
- memo: emotional, atmospheric, one-off memory, or safe fallback.

For each instance:
- applicable is the only decision field: "MOCHI should save/materialize this instance".
- evidence_score is diagnostic only, 0.0-1.0. It must not be needed for product decisions.
- payload should contain only useful typed fields visible or strongly implied by the input.
  Allowed payload fields are title, date, time, deadline, person, topic, url, note.
  Leave unknown fields null or omit them. Do not invent dates.

Top-level needs_review means "MOCHI should passively ask the user because the intent decision is under-specified or user-only".
If no instance is applicable, include a memo fallback instance.
Same intent_type may appear multiple times when there are multiple execution units.
""",
    "boolean_instances_refined": """\
MOCHI intent schema experiment.

Return intent_instances for this saved record. All output text must be Korean.
Use these 4 intent types:
- schedule: a specific time-bound event, appointment, meeting, or deadline. A year/date mentioned inside reference content is not schedule by itself.
- todo: a concrete action the user should do. Long-term goals are todo, not schedule, unless a concrete date/time exists.
- knowledge: durable reference or learning value. "나중에 공부", "읽어보기", or technical concepts are knowledge unless the user also asks to apply/do something concrete.
- memo: emotional, atmospheric, one-off memory, or safe fallback.

Decision rules:
- applicable is the only save/materialize decision field.
- needs_review means MOCHI should passively ask the user because the intent is under-specified or user-only.
- If the record is vague ("이거 나중에", "나중에 봐야지") and the object/action is not visible in text, output one applicable memo fallback and needs_review=true.
- If the user explicitly presents alternatives ("A? 아니면 B?"), set needs_review=true. Keep only instances that are safe to save without guessing; use memo fallback when neither side is concrete enough.
- Do not add schedule just because the text contains "올해", a year, or a date-like phrase inside an article title. Schedule requires an event/deadline.
- Same intent_type may appear multiple times when there are multiple execution units.

Payload:
- Allowed fields are title, date, time, deadline, person, topic, url, note.
- Fill useful typed fields visible or strongly implied by the input. Leave unknown fields null or omit them. Do not invent dates.
""",
    "instances_review_options": """\
MOCHI intent schema experiment.

Return only instances that MOCHI should save now. Do not include rejected or merely possible candidates in intent_instances.
All output text must be Korean.

Use these 4 intent types:
- schedule: a specific time-bound event, appointment, meeting, or deadline. A year/date mentioned inside reference content is not schedule by itself.
- todo: a concrete action the user should do. Long-term goals are todo, not schedule, unless a concrete date/time exists.
- knowledge: durable reference or learning value. "나중에 공부", "읽어보기", or technical concepts are knowledge unless the user also asks to apply/do something concrete.
- memo: emotional, atmospheric, one-off memory, or safe fallback.

Fields:
- intent_instances: saved/materialized instances only. If an instance is in this array, it is applicable by definition.
- needs_review: true when MOCHI should passively ask the user because the intent is under-specified or user-only.
- review_options: choices to show only when needs_review=true. These are not saved until the user chooses. Use [] when needs_review=false.

Decision rules:
- If the record is clear, output all safe intent_instances and needs_review=false.
- If the record is vague ("이거 나중에", "나중에 봐야지") and the object/action is not visible in text, save one memo fallback, set needs_review=true, and put possible choices in review_options.
- If the user explicitly presents alternatives ("A? 아니면 B?"), set needs_review=true. Save only the safest memo fallback unless one action is already concrete.
- Do not add schedule just because the text contains "올해", a year, or a date-like phrase inside an article title. Schedule requires an event/deadline.
- Same intent_type may appear multiple times when there are multiple execution units.

Payload:
- Allowed fields are title, date, time, deadline, person, topic, url, note.
- Fill useful typed fields visible or strongly implied by the input. Leave unknown fields null or omit them. Do not invent dates.
""",
}


def multiset_counts(values: list[str] | tuple[str, ...]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return counts


def f1_multiset(pred: list[str], gold: tuple[str, ...]) -> float:
    pred_counts = multiset_counts(pred)
    gold_counts = multiset_counts(gold)
    overlap = sum(min(pred_counts.get(k, 0), gold_counts.get(k, 0)) for k in set(pred_counts) | set(gold_counts))
    if not pred and not gold:
        return 1.0
    if not pred or not gold:
        return 0.0
    precision = overlap / len(pred)
    recall = overlap / len(gold)
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def derive_decision(schema_name: str, parsed: dict[str, Any], threshold: float) -> dict[str, Any]:
    if schema_name == "score_flat":
        intents = parsed.get("intents", [])
        active = [it.get("intent") for it in intents if float(it.get("applicability", 0)) >= threshold]
        if not active:
            active = ["memo"]
        max_score = max([float(it.get("applicability", 0)) for it in intents] or [0.0])
        return {
            "active": active,
            "needs_review": max_score < threshold,
            "instance_count": len(active),
            "payload_count": 0,
        }
    instances = parsed.get("intent_instances", [])
    if schema_name == "instances_review_options":
        applicable = instances
    else:
        applicable = [it for it in instances if bool(it.get("applicable"))]
    if not applicable:
        applicable = [{"intent_type": "memo", "payload": {}}]
    return {
        "active": [it.get("intent_type") for it in applicable],
        "needs_review": bool(parsed.get("needs_review")),
        "instance_count": len(applicable),
        "payload_count": sum(1 for it in applicable if isinstance(it.get("payload"), dict) and bool(it["payload"])),
    }


def payload_quality(parsed: dict[str, Any]) -> float:
    instances = parsed.get("intent_instances", [])
    applicable = instances if "review_options" in parsed else [it for it in instances if bool(it.get("applicable"))]
    if not applicable:
        return 0.0
    good = 0
    for it in applicable:
        payload = it.get("payload")
        if isinstance(payload, dict) and any(v not in (None, "", [], {}) for v in payload.values()):
            good += 1
    return good / len(applicable)


def call_model(client: genai.Client, schema_name: str, case: Case) -> tuple[dict[str, Any], float, str | None]:
    config = types.GenerateContentConfig(
        system_instruction=PROMPTS[schema_name],
        temperature=0.1,
        max_output_tokens=2048,
        response_mime_type="application/json",
        response_schema=SCHEMAS[schema_name],
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    user_prompt = (
        "Analyze this saved record. Return JSON only.\n\n"
        f"Record:\n{case.input}\n"
    )
    t0 = time.perf_counter()
    response = client.models.generate_content(model=MODEL, contents=user_prompt, config=config)
    latency_ms = (time.perf_counter() - t0) * 1000
    try:
        return json.loads(response.text), latency_ms, None
    except json.JSONDecodeError as exc:
        return {"_raw": response.text}, latency_ms, str(exc)


def run(limit: int | None = None) -> dict[str, Any]:
    client = genai.Client(vertexai=True, location=LOCATION)
    cases = CASES[:limit] if limit else CASES
    rows: list[dict[str, Any]] = []
    thresholds = [0.5, 0.6, 0.7]

    for schema_name in SCHEMAS:
        for idx, case in enumerate(cases, 1):
            parsed, latency_ms, error = call_model(client, schema_name, case)
            threshold_metrics: dict[str, Any] = {}
            threshold_iter = thresholds if schema_name == "score_flat" else [0.6]
            for threshold in threshold_iter:
                decision = derive_decision(schema_name, parsed, threshold)
                f1 = f1_multiset([str(v) for v in decision["active"]], case.gold_active)
                threshold_metrics[str(threshold)] = {
                    **decision,
                    "intent_f1": round(f1, 4),
                    "instance_count_exact": decision["instance_count"] == case.gold_instance_count,
                    "review_correct": decision["needs_review"] == case.gold_needs_review,
                }
            row = {
                "schema": schema_name,
                "case_id": case.id,
                "input": case.input,
                "gold_active": list(case.gold_active),
                "gold_instance_count": case.gold_instance_count,
                "gold_needs_review": case.gold_needs_review,
                "note": case.note,
                "latency_ms": round(latency_ms, 1),
                "error": error,
                "parsed": parsed,
                "metrics": threshold_metrics,
                "payload_quality": round(payload_quality(parsed), 4) if schema_name != "score_flat" else None,
            }
            rows.append(row)
            metric = threshold_metrics["0.6"]
            print(
                f"[{schema_name} {idx:02d}/{len(cases)}] {case.id}: "
                f"active={metric['active']} review={metric['needs_review']} "
                f"f1={metric['intent_f1']} count={metric['instance_count_exact']} "
                f"review_ok={metric['review_correct']} {latency_ms:.0f}ms",
                file=sys.stderr,
            )

    summary: dict[str, Any] = {
        "model": MODEL,
        "location": LOCATION,
        "n_cases": len(cases),
        "schemas": {},
        "rows": rows,
    }
    for schema_name in SCHEMAS:
        schema_rows = [r for r in rows if r["schema"] == schema_name]
        threshold_iter = thresholds if schema_name == "score_flat" else [0.6]
        by_threshold: dict[str, Any] = {}
        for threshold in threshold_iter:
            key = str(threshold)
            metrics = [r["metrics"][key] for r in schema_rows]
            by_threshold[key] = {
                "mean_intent_f1": round(statistics.mean(m["intent_f1"] for m in metrics), 4),
                "instance_count_accuracy": round(statistics.mean(m["instance_count_exact"] for m in metrics), 4),
                "review_accuracy": round(statistics.mean(m["review_correct"] for m in metrics), 4),
            }
        payload_values = [r["payload_quality"] for r in schema_rows if r["payload_quality"] is not None]
        summary["schemas"][schema_name] = {
            "thresholds": by_threshold,
            "payload_quality": round(statistics.mean(payload_values), 4) if payload_values else None,
            "mean_latency_ms": round(statistics.mean(r["latency_ms"] for r in schema_rows), 1),
            "errors": sum(1 for r in schema_rows if r["error"]),
        }
    return summary


def write_report(summary: dict[str, Any]) -> None:
    lines: list[str] = []
    lines.append("# Intent schema decision bench")
    lines.append("")
    lines.append(f"- model: `{summary['model']}`")
    lines.append(f"- cases: {summary['n_cases']}")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| schema | threshold | intent F1 | count acc | review acc | payload quality |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for schema_name, data in summary["schemas"].items():
        for threshold, metrics in data["thresholds"].items():
            payload = data["payload_quality"]
            payload_text = f"{payload:.3f}" if payload is not None else "n/a"
            lines.append(
                f"| {schema_name} | {threshold} | {metrics['mean_intent_f1']:.3f} | "
                f"{metrics['instance_count_accuracy']:.3f} | {metrics['review_accuracy']:.3f} | "
                f"{payload_text} |"
            )
    lines.append("")
    lines.append("## Per-case outputs at decision threshold 0.6")
    lines.append("")
    for row in summary["rows"]:
        metric = row["metrics"]["0.6"]
        lines.append(
            f"- `{row['schema']}` / `{row['case_id']}`: active={metric['active']}, "
            f"needs_review={metric['needs_review']}, f1={metric['intent_f1']}, "
            f"count_exact={metric['instance_count_exact']}, review_ok={metric['review_correct']}"
        )
    lines.append("")
    REPORT_MD.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    summary = run(limit=args.limit)
    RESULTS_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    write_report(summary)
    print(f"\nresults: {RESULTS_JSON}", file=sys.stderr)
    print(f"report:  {REPORT_MD}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
