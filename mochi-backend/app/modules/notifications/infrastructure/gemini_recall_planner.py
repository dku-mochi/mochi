"""알림 설계 Agent — Vertex AI Gemini 어댑터 (`RecallPlannerPort` 구현, P2).

notification-agent.md §2.2 의 플래너. 비용 우선 flash-lite + thinking_budget=0(settings.gemini_agent_model).

모듈 경계(부모 Claude 결정): notifications 는 agent.infrastructure(gemini_agent_client 등)를 직접
import 하지 않는다(타모듈 비공개). genai 사용 패턴(_shared_client / Content 변환 / function_call 추출)을
**읽어 참고**하되 여기 독립 어댑터로 둔다(복제 최소화 — 단일 함수콜 + 선택적 1-tool 루프라 단순).

tool loop: `get_scheduled(date)` 1종만. "일반 시간대 발송이면 필수 호출"(묶기·중복방지). 모델이 이를
부르면 ScheduledLookup 으로 그날 예정 알림을 돌려주고 다시 호출 — finalize 가 나오면 종료.
finalize = `finalizeNotificationPlan(plan_kind, stages)` 구조화 출력. plan_kind="none" = 알림 없음
("애매하면 안 보낸다", §3). supersede 는 유스케이스가 결정적으로 처리(같은 source_intent 의 기존
active plan 교체)하므로 LLM 출력에 두지 않는다 — 어댑터엔 plan id 컨텍스트가 없어 환각 위험만 있다.
"""

import asyncio
import json
from functools import lru_cache
from typing import Any, cast
from uuid import UUID

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.notifications.domain.recall_plan import PlanKind
from app.modules.notifications.domain.recall_planning import (
    EligibleCandidate,
    PlannerDecision,
    PlanningContext,
    RecallPlannerPort,
    ScheduledLookup,
)
from app.modules.notifications.infrastructure.recall_planner_prompt import (
    RECALL_PLANNER_PROMPT,
    RECALL_PROMPT_VERSION,
)

logger = structlog.get_logger(__name__)

_FINALIZE = "finalizeNotificationPlan"
_GET_SCHEDULED = "get_scheduled"
_MAX_TOOL_ROUNDS = 3  # get_scheduled 왕복 상한 — 폭주 방지(보통 0~1회).

# stages DSL 의 trigger 모양(schema.md §3). LLM 이 직접 채운다 — extra 키는 Pydantic 검증에서 컷.
_TRIGGER_PROPS: dict[str, Any] = {
    "type": {"type": "string", "enum": ["relative", "recurring", "spaced"]},
    "anchor": {"type": "string", "enum": ["deadline", "event_date", "saved_at"]},
    "offset": {"type": "string"},
    "interval_days": {"type": "integer"},
    "max_occurrences": {"type": "integer"},
    "until_anchor": {"type": "string", "enum": ["deadline", "event_date", "saved_at"]},
    "schedule_days": {"type": "array", "items": {"type": "integer"}},
}

_STAGE_PROPS: dict[str, Any] = {
    "seq": {"type": "integer"},
    "trigger": {"type": "object", "properties": _TRIGGER_PROPS, "required": ["type"]},
    "time_hint": {"type": "string"},
    "content_template": {"type": "string"},
    "importance_hint": {"type": "string", "enum": ["heavy", "light"]},
}

_FINALIZE_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        # "none" = 알림 안 만든다(애매하면 보류). 그 외는 plan_kind ↔ trigger.type 이 정합해야 한다.
        "plan_kind": {
            "type": "string",
            "enum": ["deadline_backoff", "recurring_nudge", "spaced", "none"],
        },
        "stages": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": _STAGE_PROPS,
                "required": ["seq", "trigger", "content_template"],
            },
        },
    },
    "required": ["plan_kind"],
}

_GET_SCHEDULED_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {"date": {"type": "string"}},  # 'YYYY-MM-DD' (KST)
    "required": ["date"],
}


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _decls() -> list[types.FunctionDeclaration]:
    return [
        types.FunctionDeclaration(
            name=_GET_SCHEDULED,
            description=(
                "List notifications already scheduled for a given KST date (YYYY-MM-DD). "
                "Call this before finalizing a general daytime notification to bundle with "
                "existing ones and avoid spamming the same day."
            ),
            parameters=_GET_SCHEDULED_PARAMS,
        ),
        types.FunctionDeclaration(
            name=_FINALIZE,
            description=(
                "Emit the final notification plan. Call exactly once when ready. "
                "Set plan_kind='none' (no stages needed) to send nothing when uncertain."
            ),
            parameters=_FINALIZE_PARAMS,
        ),
    ]


def _build_user_prompt(candidate: EligibleCandidate, context: PlanningContext) -> str:
    """후보 + 맥락을 텍스트 한 덩어리로. similar 가 비면 생략(설계 허용)."""
    lines: list[str] = []
    lines.append(f"# 현재 시각(KST): {context.now_kst.isoformat()}")
    lines.append("")
    lines.append("# 알림을 설계할 대상")
    lines.append(f"- intent_type: {candidate.intent_type}")
    lines.append(f"- 게이트 추천 plan_kind: {candidate.suggested_plan_kind.value}")
    lines.append(f"- 제목: {candidate.title or '(없음)'}")
    if candidate.label:
        lines.append(f"- 라벨: {candidate.label}")
    if candidate.anchor_value:
        lines.append(f"- 기준 날짜(마감/일정): {candidate.anchor_value}")
    lines.append("")
    if context.recent:
        lines.append("# 최근 저장 기록 (난사 억제·묶기 판단용)")
        for it in context.recent[:10]:
            lines.append(f"- {it.title or it.summary or '(요약없음)'} [{it.category or '미분류'}]")
        lines.append("")
    if context.similar:
        lines.append("# 유사 저장 기록")
        for it in context.similar[:10]:
            lines.append(f"- {it.summary or '(요약없음)'} [{it.category or '미분류'}]")
        lines.append("")
    if context.past_notifications:
        lines.append("# 과거 보낸 알림 (opened 있으면 양성 신호 — 안 누름은 부정 아님)")
        for n in context.past_notifications[:10]:
            opened = "열어봄" if n.opened_at else "반응없음"
            lines.append(f"- {n.title} ({opened})")
        lines.append("")
    return "\n".join(lines)


async def _call(*, system_prompt: str, contents: list[types.Content], model: str) -> Any:
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=1024,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        tools=[types.Tool(function_declarations=_decls())],
        tool_config=types.ToolConfig(function_calling_config=types.FunctionCallingConfig(mode="ANY")),
    )
    return await _shared_client().aio.models.generate_content(
        model=model, contents=cast(types.ContentListUnion, contents), config=cfg
    )


def _extract_function_call(resp: Any) -> tuple[str, dict[str, Any], bytes | None] | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None):
                return fc.name, dict(fc.args or {}), getattr(part, "thought_signature", None)
    return None


def _to_decision(args: dict[str, Any], model: str) -> PlannerDecision | None:
    plan_kind_raw = str(args.get("plan_kind", "none"))
    if plan_kind_raw == "none":
        return None
    try:
        plan_kind = PlanKind(plan_kind_raw)
    except ValueError:
        return None
    stages = args.get("stages") or []
    return PlannerDecision(
        plan_kind=plan_kind,
        # 유스케이스가 RecallPlanStages.model_validate(...).validate_for(plan_kind) 로 검증한다.
        stages={"dsl_version": "1", "stages": stages},
        generated_model=f"{model}/{RECALL_PROMPT_VERSION}",
    )


class GeminiRecallPlanner(RecallPlannerPort):
    def __init__(
        self, *, owner_id: UUID, model: str | None = None, timeout_seconds: float | None = None
    ) -> None:
        settings = get_settings()
        # owner_id 는 get_scheduled 호출을 owner-scope 로 묶기 위해 어댑터에 바인드(후보엔 owner 없음).
        self._owner_id = owner_id
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def plan(
        self,
        *,
        candidate: EligibleCandidate,
        context: PlanningContext,
        get_scheduled: ScheduledLookup,
    ) -> PlannerDecision | None:
        contents: list[types.Content] = [
            types.Content(role="user", parts=[types.Part(text=_build_user_prompt(candidate, context))])
        ]
        for _ in range(_MAX_TOOL_ROUNDS + 1):
            resp = await asyncio.wait_for(
                _call(
                    system_prompt=RECALL_PLANNER_PROMPT,
                    contents=contents,
                    model=self._model,
                ),
                timeout=self._timeout,
            )
            fc = _extract_function_call(resp)
            if fc is None:
                logger.warning("recall.planner.no_function_call", model=self._model)
                return None
            name, args, signature = fc
            if name == _FINALIZE:
                logger.info("recall.planner.finalize", model=self._model, plan_kind=args.get("plan_kind"))
                return _to_decision(args, self._model)
            if name == _GET_SCHEDULED:
                date = str(args.get("date", ""))[:10]
                scheduled = await get_scheduled.for_date(owner_id=self._owner_id, date_kst=date)
                response_payload = {
                    "scheduled": [
                        {"title": s.title, "fire_at": s.fire_at.isoformat(), "kind": s.kind}
                        for s in scheduled
                    ]
                }
                # thought_signature 는 Part 에 echo back(멀티턴 필수, agent client 와 동형).
                contents.append(
                    types.Content(
                        role="model",
                        parts=[
                            types.Part(
                                function_call=types.FunctionCall(name=name, args=args),
                                thought_signature=signature,
                            )
                        ],
                    )
                )
                contents.append(
                    types.Content(
                        role="user",
                        parts=[
                            types.Part.from_function_response(
                                name=name,
                                response=json.loads(json.dumps(response_payload, default=str)),
                            )
                        ],
                    )
                )
                continue
            logger.warning("recall.planner.unknown_tool", model=self._model, tool=name)
            return None
        # 루프 상한 도달(finalize 없음) — 보수적으로 미생성.
        logger.warning("recall.planner.max_rounds", model=self._model)
        return None
