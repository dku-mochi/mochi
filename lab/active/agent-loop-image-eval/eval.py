"""이미지 agent loop eval — 로컬 스크린샷 → Gemini 분석 → JSON 결과.

실행:
  GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \\
    python lab/active/agent-loop-image-eval/eval.py

데이터 배치:
  lab/data/screenshot/<gold_intents>_<actual_intention>.PNG
  - gold_intents: 파일명 앞쪽의 연속된 valid intent 토큰 (todo/schedule/knowledge/memo)
  - actual_intention: 첫 번째 non-intent 토큰부터 끝까지 (자유 텍스트)
  예) todo_이신발을구매후보로저장.PNG        → intents=[todo]
      schedule_todo_비행기스케줄.PNG        → intents=[schedule, todo]
      memo_knowledge_식단짤때참고하려고.PNG → intents=[memo, knowledge]

결과:
  lab/active/agent-loop-image-eval/results/YYYYMMDD_HHMMSS.json

평가 항목:
  - tool_eval       : Agent가 사용한 툴 목록 (finalizeAnalysis 제외 — final_payload 이벤트로 처리됨)
  - intent_eval     : Gold Intent vs 예측 Intent (Recall / Precision / Exact match)
  - intention_judge : 실제 저장 의도 ↔ Agent 분석 결과 의미 정합성 (LLM Judge)
"""
import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field


class JudgeResult(BaseModel):
    alignment_score: int = Field(ge=1, le=5)
    captures_core_intention: bool
    contradicts_intention: bool
    missing_points: list[str]
    reasoning: str

sys.stdout.reconfigure(encoding="utf-8")

# lab_gemini_client 는 같은 디렉토리
sys.path.insert(0, str(Path(__file__).parent))
from lab_gemini_client import LabGeminiClient  # noqa: E402

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.analysis import AnalysisResult  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.profile import ProfileWindowItem  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import _shared_client  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402

LAB_ROOT = Path(__file__).parent
DATA_DIR = Path(__file__).parent.parent.parent / "data" / "screenshot"
RESULTS_DIR = LAB_ROOT / "results"
MAX_STEPS = 8

VALID_INTENTS = {"schedule", "todo", "knowledge", "memo"}
MIME_MAP = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def parse_gold(stem: str) -> tuple[list[str], str]:
    """파일명 stem에서 Gold Intent 목록과 실제 저장 의도를 파싱.

    앞쪽의 연속된 VALID_INTENTS 토큰을 intent로, 이후를 actual_intention으로 처리.
    예) memo_나중에살화장품        → ([memo], 나중에살화장품)
        schedule_todo_비행기스케줄 → ([schedule, todo], 비행기스케줄)
    """
    parts = stem.split("_")
    intents: list[str] = []
    split_at = 0
    for i, part in enumerate(parts):
        if part.lower() in VALID_INTENTS:
            intents.append(part.lower())
            split_at = i + 1
        else:
            break

    actual_intention = "_".join(parts[split_at:])

    if not intents:
        raise ValueError(f"intent 없음: {stem}")
    if len(intents) != len(set(intents)):
        raise ValueError(f"중복 intent: {stem}")
    if not actual_intention.strip():
        raise ValueError("실제 저장 의도가 비어 있음")

    return intents, actual_intention


class _FakeGateway:
    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied: AnalysisResult | None = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def list_recent_window(self, *, owner_id, limit) -> list[ProfileWindowItem]:
        return []

    async def count_items(self, *, owner_id):
        return 0


async def judge_intention_alignment(
    actual_intention: str,
    analysis: AnalysisResult,
) -> dict[str, Any]:
    """LLM as a judge — 실제 저장 의도 ↔ Agent 분석 결과 의미 정합성 평가."""
    from google.genai import types

    settings = get_settings()
    predicted = {
        "summary": analysis.summary,
        "intents": [
            {
                "intent_type": inst.intent_type.value,
                "label": inst.label,
                "reasoning": inst.reasoning,
                "payload": {
                    "title": inst.payload.title,
                    "topic": inst.payload.topic,
                    "note": inst.payload.note,
                },
            }
            for inst in analysis.intent_instances
        ],
    }
    prompt = (
        f"사용자의 실제 저장 의도: {actual_intention}\n\n"
        f"Agent 분석 결과: {json.dumps(predicted, ensure_ascii=False)}\n\n"
        "위 분석 결과가 사용자의 실제 저장 의도와 의미적으로 얼마나 일치하는지 평가해줘.\n"
        "평가 항목:\n"
        "- 핵심 저장 목적을 포착했는가\n"
        "- 실제 의도와 충돌하는 내용이 있는가\n"
        "- 중요한 의도를 누락했는가\n\n"
        "alignment_score: 1-5 (5=완벽히 일치, 4=대체로 일치, 3=핵심은 맞지만 누락, 2=부분적, 1=거의 불일치)\n"
        '{"alignment_score": <int 1-5>, "captures_core_intention": <bool>, '
        '"contradicts_intention": <bool>, "missing_points": [<str>], '
        '"reasoning": "<한 줄>"} 형식으로만 응답.'
    )

    def _call():
        client = _shared_client()
        return client.models.generate_content(
            model=settings.gemini_agent_model,
            contents=[types.Content(role="user", parts=[types.Part(text=prompt)])],
            config=types.GenerateContentConfig(
                temperature=0.0,
                max_output_tokens=512,
                response_mime_type="application/json",
                response_schema=JudgeResult,
            ),
        )

    try:
        resp = await asyncio.to_thread(_call)
        return JudgeResult.model_validate_json(resp.text).model_dump()
    except Exception as exc:
        return {
            "alignment_score": None,
            "captures_core_intention": None,
            "contradicts_intention": None,
            "missing_points": [],
            "reasoning": f"judge 오류: {exc}",
        }


async def run_case(
    image_path: Path,
    expected_intents: list[str],
    actual_intention: str,
) -> dict[str, Any]:
    mime = MIME_MAP.get(image_path.suffix.lower(), "image/png")
    source = AnalysisInput(text=None, url=None, user_memo=None, images=[(str(image_path), mime)])
    gateway = _FakeGateway(source)
    orch = AgentOrchestrator(
        llm=LabGeminiClient(),
        tools=StaticToolRegistry(),
        max_steps=MAX_STEPS,
        gateway=gateway,
    )

    tools_called: list[str] = []
    events: list[str] = []
    try:
        async for ev in orch.run(uuid4(), uuid4()):
            events.append(ev.kind)
            if ev.kind == "tool_started":
                tools_called.append(ev.payload["name"])
    except Exception as exc:
        return {"file": image_path.name, "error": str(exc), "events": events}

    a = gateway.applied
    if a is None:
        return {"file": image_path.name, "error": "분석 결과 없음", "events": events}

    predicted_intents = [inst.intent_type.value for inst in a.intent_instances]
    gold = set(expected_intents)
    predicted = set(predicted_intents)
    intersection = gold & predicted
    recall = len(intersection) / len(gold) if gold else 0.0
    precision = len(intersection) / len(predicted) if predicted else 0.0
    exact_match = gold == predicted

    predicted_analysis = {
        "summary": a.summary,
        "intents": [
            {
                "intent_type": inst.intent_type.value,
                "label": inst.label,
                "reasoning": inst.reasoning,
                "payload": {
                    "title": inst.payload.title,
                    "topic": inst.payload.topic,
                    "note": inst.payload.note,
                },
            }
            for inst in a.intent_instances
        ],
    }
    judge = await judge_intention_alignment(actual_intention, a)

    return {
        "file": image_path.name,
        "actual_intention": actual_intention,
        "expected_intents": expected_intents,
        "predicted_intents": predicted_intents,
        "tool_eval": {
            "tools_called": tools_called,
        },
        "intent_eval": {
            "recall": recall,
            "precision": precision,
            "exact_match": exact_match,
            "needs_review": a.needs_review,
        },
        "predicted_analysis": predicted_analysis,
        "intention_judge": judge,
        "events": events,
    }


async def main() -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []

    if not DATA_DIR.exists():
        print(f"[오류] 데이터 디렉터리 없음: {DATA_DIR}")
        return

    images = sorted(f for f in DATA_DIR.iterdir() if f.suffix.lower() in MIME_MAP)
    if not images:
        print(f"[skip] {DATA_DIR} 이미지 없음")
        return

    for image_path in images:
        try:
            expected_intents, actual_intention = parse_gold(image_path.stem)
        except ValueError as e:
            reason = str(e)
            print(f"[skip] {image_path.name}: {reason}")
            skipped.append({"file": image_path.name, "reason": reason})
            continue

        print(f"\n{image_path.name}", flush=True)
        print(f"  gold={expected_intents}  의도={actual_intention}")

        result = await run_case(image_path, expected_intents, actual_intention)
        result["intent_count"] = len(expected_intents)
        results.append(result)

        if "error" in result:
            print(f"  -> ERROR: {result['error']}")
            continue

        ei = result["intent_eval"]
        j = result["intention_judge"]
        print(
            f"  -> predicted={result['predicted_intents']}"
            f"  recall={ei['recall']:.2f}  precision={ei['precision']:.2f}"
            f"  exact={ei['exact_match']}"
        )
        print(f"  -> judge: {j.get('alignment_score')}/5  {j.get('reasoning', '')[:60]}")

    valid = [r for r in results if "error" not in r]
    if valid:
        avg_recall = sum(r["intent_eval"]["recall"] for r in valid) / len(valid)
        avg_precision = sum(r["intent_eval"]["precision"] for r in valid) / len(valid)
        exact_rate = sum(1 for r in valid if r["intent_eval"]["exact_match"]) / len(valid)
        scores = [
            r["intention_judge"]["alignment_score"]
            for r in valid
            if r["intention_judge"]["alignment_score"] is not None
        ]
        avg_score = sum(scores) / len(scores) if scores else None
        judge_with_result = [
            r for r in valid
            if r["intention_judge"].get("contradicts_intention") is not None
        ]
        contradiction_rate = (
            sum(1 for r in judge_with_result if r["intention_judge"]["contradicts_intention"])
            / len(judge_with_result)
            if judge_with_result
            else None
        )

        summary: dict[str, Any] = {
            "total": len(results),
            "valid": len(valid),
            "skipped": len(skipped),
            "avg_intent_recall": round(avg_recall, 3),
            "avg_intent_precision": round(avg_precision, 3),
            "exact_set_match_rate": round(exact_rate, 3),
            "avg_alignment_score": round(avg_score, 2) if avg_score is not None else None,
            "contradiction_rate": round(contradiction_rate, 3) if contradiction_rate is not None else None,
        }
        print("\n--- 집계 ---")
        for k, v in summary.items():
            print(f"  {k}: {v}")
    else:
        summary = {"total": len(results), "valid": 0, "skipped": len(skipped)}

    output = {"summary": summary, "cases": results, "skipped_cases": skipped}
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = RESULTS_DIR / f"{ts}.json"
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n결과 저장: {out_path}  ({len(results)}건)")


if __name__ == "__main__":
    asyncio.run(main())
