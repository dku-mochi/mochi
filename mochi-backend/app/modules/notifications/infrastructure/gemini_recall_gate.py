"""트랙 C 회수 선별 게이트 — Vertex AI Gemini 어댑터 (`RecallGatePort` 구현, 2026-06-17).

정본 `journal/proactive-recall/track-c-llm-gate-decision.md` §5,§7. 트랙 A/B 의 `GeminiRecallPlanner`
와 동형(genai client / call / function-call 추출 패턴 재사용). 단일 함수콜 `submitRecallDecision`
구조화 출력 — tool loop 불필요(v5 프롬프트는 컨텍스트 자급). 비용 우선 flash-lite + thinking_budget=0.
temperature=0.2 는 실험(v5) 재현값 — 다양성은 프롬프트 anti-template 가 담당.

모듈 경계: notifications 는 agent.infrastructure 를 직접 import 하지 않는다 — genai 를 여기 독립
어댑터에서 직접 쓴다(planner 와 동일). best-effort: 호출 실패는 호출부(use case)가 skip 처리한다.
"""

import asyncio
from functools import lru_cache
from typing import Any, cast

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.notifications.domain.recall_gate import (
    RecallGateDecision,
    RecallGateInput,
    RecallGatePort,
)
from app.modules.notifications.infrastructure.recall_gate_prompt import (
    RECALL_GATE_PROMPT,
    RECALL_GATE_VERSION,
)

logger = structlog.get_logger(__name__)

_SUBMIT = "submitRecallDecision"

_SUBMIT_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "recall": {"type": "boolean"},
        "chosen_index": {"type": "integer"},
        "relation": {
            "type": "string",
            "enum": ["comparison", "followup", "reference", "none"],
        },
        "confidence": {"type": "number"},
        "message": {"type": "string"},
        "reason": {"type": "string"},
    },
    "required": ["recall"],
}

_DECLINE = RecallGateDecision(
    recall=False, chosen_index=None, relation="none", confidence=0.0, message="", reason="no_decision"
)


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
            name=_SUBMIT,
            description="Emit the recall decision. Call exactly once.",
            parameters=_SUBMIT_PARAMS,
        )
    ]


def _build_prompt(gate_input: RecallGateInput) -> str:
    lines = [
        "# 방금 저장한 기록 B",
        f"- 제목: {gate_input.trigger_title}",
        f"- 요약: {gate_input.trigger_summary or '(요약없음)'}",
        f"- 종류: {list(gate_input.trigger_types)}",
        "",
        "# 과거 기록 후보",
    ]
    for c in gate_input.candidates:
        gap = f"{c.gap_days:.1f}일전" if c.gap_days >= 1 else f"{c.gap_days * 24:.0f}시간전"
        lines.append(
            f"[{c.index}] {c.title} | {list(c.intent_types)} | {gap} | sim {c.score:.2f}"
        )
    lines.append("")
    lines.append("chosen_index 는 위 [n] 기준. 없거나 무가치하면 recall=false.")
    return "\n".join(lines)


def _extract_args(resp: Any) -> dict[str, Any] | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None) == _SUBMIT:
                return dict(fc.args or {})
    return None


def _to_decision(args: dict[str, Any]) -> RecallGateDecision:
    recall = bool(args.get("recall"))
    ci = args.get("chosen_index")
    message = str(args.get("message", "") or "").strip()
    if recall and not message:
        # generic copy 금지(§4): 본문 없으면 발송 가치 없음 — decline.
        return _DECLINE
    return RecallGateDecision(
        recall=recall,
        chosen_index=int(ci) if (recall and ci is not None) else None,
        relation=str(args.get("relation", "none") or "none"),
        confidence=float(args.get("confidence", 0.0) or 0.0),
        message=message,
        reason=str(args.get("reason", "") or "")[:120],
    )


class GeminiRecallGate(RecallGatePort):
    def __init__(self, *, model: str | None = None, timeout_seconds: float | None = None) -> None:
        settings = get_settings()
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def decide(self, *, gate_input: RecallGateInput) -> RecallGateDecision:
        if not gate_input.candidates:
            return _DECLINE
        cfg = types.GenerateContentConfig(
            system_instruction=RECALL_GATE_PROMPT,
            temperature=0.2,
            max_output_tokens=512,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
            tools=[types.Tool(function_declarations=_decls())],
            tool_config=types.ToolConfig(
                function_calling_config=types.FunctionCallingConfig(mode="ANY")
            ),
        )
        resp = await asyncio.wait_for(
            _shared_client().aio.models.generate_content(
                model=self._model,
                contents=cast(types.ContentListUnion, _build_prompt(gate_input)),
                config=cfg,
            ),
            timeout=self._timeout,
        )
        args = _extract_args(resp)
        if args is None:
            logger.warning("recall.gate.no_function_call", model=self._model)
            return _DECLINE
        decision = _to_decision(args)
        logger.info(
            "recall.gate.decision",
            model=f"{self._model}/{RECALL_GATE_VERSION}",
            recall=decision.recall,
            relation=decision.relation,
            confidence=round(decision.confidence, 2),
        )
        return decision
