"""이미지 agent loop eval — 로컬 스크린샷 → Gemini 분석 → JSON 결과.

실행:
  GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \\
    python lab/active/agent-loop-image-eval/eval.py

데이터 배치:
  lab/data/screenshot/intent_N/<설명_intent>.PNG
  - 폴더명: 기대 intent 개수 (intent_1 ~ intent_4)
  - 파일명: 끝 토큰에 기대 intent 를 '_' 로 구분해 포함
  예) 마우스구매고민_memo.PNG        → 기대: [memo]
      OS과제제출마감_todo.PNG        → 기대: [todo]
      LangChain공부_knowledge_todo.PNG → 기대: [knowledge, todo]

결과:
  lab/active/agent-loop-image-eval/results/YYYYMMDD_HHMMSS.json

평가 항목:
  - tool_eval  : finalizeAnalysis 호출 여부 + 사용한 툴 목록
  - intent_eval: 기대 intent vs 실제 primary/secondary
  - judge      : LLM as a judge — summary 정확도 1-5점
"""
import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

# lab_gemini_client 는 같은 디렉토리
sys.path.insert(0, str(Path(__file__).parent))
from lab_gemini_client import LabGeminiClient

from app.core.config import get_settings
from app.modules.agent.application.orchestrator import AgentOrchestrator
from app.modules.agent.domain.analysis import AnalysisResult
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.agent.domain.profile import ProfileWindowItem
from app.modules.agent.infrastructure.gemini_agent_client import _shared_client
from app.modules.agent.infrastructure.registry import StaticToolRegistry

LAB_ROOT = Path(__file__).parent
DATA_DIR = Path(__file__).parent.parent.parent / "data" / "screenshot"
RESULTS_DIR = LAB_ROOT / "results"
MAX_STEPS = 8

VALID_INTENTS = {"schedule", "todo", "knowledge", "memo"}
MIME_MAP = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def parse_expected_intents(stem: str) -> list[str]:
    """파일명 stem 끝 토큰 중 알려진 intent 를 순서대로 추출."""
    parts = stem.lower().split("_")
    return [p for p in parts if p in VALID_INTENTS]


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


async def judge_summary(image_path: Path, mime: str, summary: str) -> dict[str, Any]:
    """LLM as a judge — 이미지와 summary 정합성을 1-5점으로 평가."""
    from google.genai import types

    settings = get_settings()
    prompt = (
        "이 이미지를 보고 아래 요약이 얼마나 정확한지 평가해줘.\n\n"
        f"요약: {summary}\n\n"
        "점수 기준: 5=완벽, 4=대체로 정확, 3=핵심은 맞지만 누락, 2=부분적, 1=거의 틀림\n"
        '{"score": <int 1-5>, "reasoning": "<한 줄>"} 형식으로만 응답.'
    )

    def _call():
        client = _shared_client()
        return client.models.generate_content(
            model=settings.gemini_agent_model,
            contents=[
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_bytes(data=image_path.read_bytes(), mime_type=mime),
                        types.Part(text=prompt),
                    ],
                )
            ],
            config=types.GenerateContentConfig(
                temperature=0.0,
                max_output_tokens=256,
                response_mime_type="application/json",
            ),
        )

    try:
        resp = await asyncio.to_thread(_call)
        return json.loads(resp.text)
    except Exception as exc:
        return {"score": None, "reasoning": f"judge 오류: {exc}"}


async def run_case(image_path: Path, expected_intents: list[str]) -> dict[str, Any]:
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

    judge = await judge_summary(image_path, mime, a.summary)

    actual_intents = [inst.intent_type.value for inst in a.intent_instances]
    return {
        "file": image_path.name,
        "expected_intents": expected_intents,
        "tool_eval": {
            "tools_called": tools_called,
            "called_finalize": "finalizeAnalysis" in tools_called,
        },
        "intent_eval": {
            "instances": actual_intents,
            "needs_review": a.needs_review,
            "expected": expected_intents,
            "match": all(e in actual_intents for e in expected_intents) if expected_intents else None,
            "count_match": len(actual_intents) == len(expected_intents) if expected_intents else None,
        },
        "summary": a.summary,
        "importance": a.importance,
        "entities": [(e.kind, e.value) for e in a.entities],
        "judge": judge,
        "events": events,
    }


async def main() -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []

    for intent_count in range(1, 5):
        folder = DATA_DIR / f"intent_{intent_count}"
        if not folder.exists():
            print(f"[skip] {folder} 없음")
            continue
        images = sorted(f for f in folder.iterdir() if f.suffix.lower() in MIME_MAP)
        if not images:
            print(f"[skip] {folder} 이미지 없음")
            continue

        for image_path in images:
            expected = parse_expected_intents(image_path.stem)
            print(f"\n[intent_{intent_count}] {image_path.name}  기대={expected}", flush=True)

            result = await run_case(image_path, expected)
            result["intent_count"] = intent_count
            results.append(result)

            if "error" in result:
                print(f"  → ERROR: {result['error']}")
                continue

            ei = result["intent_eval"]
            print(f"  → instances={ei['instances']}  match={ei['match']}  needs_review={ei['needs_review']}")
            print(f"  → summary: {result['summary'][:80]}")
            j = result["judge"]
            print(f"  → judge: {j.get('score')}/5  {j.get('reasoning', '')[:60]}")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = RESULTS_DIR / f"{ts}.json"
    out_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n결과 저장: {out_path}  ({len(results)}건)")


if __name__ == "__main__":
    asyncio.run(main())
