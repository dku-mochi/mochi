"""`UserProfileSummarizer` 구현 — 최근 window 를 받아 사용자 특성 요약 생성.

비용 최우선: agent loop 와 동일 flash-lite + ``thinking_budget=0``. 짧은 출력(≤512 tok).
SDK native async (``.aio``) + ``asyncio.wait_for`` 패턴 (agent client 와 동일).
"""

import asyncio
from functools import lru_cache

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.agent.domain.profile import ProfileWindowItem, UserProfileSummarizer
from app.modules.agent.prompts.system_prompts import PROFILE_SUMMARY_SYSTEM

logger = structlog.get_logger(__name__)


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _format_window(window: list[ProfileWindowItem], previous: str | None) -> str:
    lines: list[str] = []
    if previous:
        lines.append(f"# 이전 프로필\n{previous}\n")
    lines.append("# 최근 저장 항목 (최신순)")
    for i, it in enumerate(window, 1):
        intents = "/".join(t.value for t in it.intent_types) or "-"
        # raw 캡처 본문은 보내지 않는다 — AI 추상(summary)만. (PRIVACY 최소전송)
        body = (it.summary or "(분석 전)").strip()
        memo = f" | 메모: {it.user_memo}" if it.user_memo else ""
        lines.append(f"{i}. [{intents}] {body[:200]}{memo}")
    return "\n".join(lines)


async def _call(*, prompt: str, model: str) -> str:
    cfg = types.GenerateContentConfig(
        system_instruction=PROFILE_SUMMARY_SYSTEM,
        temperature=0.4,
        max_output_tokens=512,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    resp = await _shared_client().aio.models.generate_content(
        model=model, contents=[prompt], config=cfg
    )
    return resp.text or ""


class GeminiProfileSummarizer(UserProfileSummarizer):
    def __init__(self, model: str | None = None, timeout_seconds: float | None = None):
        settings = get_settings()
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def summarize(
        self, *, window: list[ProfileWindowItem], previous: str | None
    ) -> str:
        if not window:
            return previous or ""
        prompt = _format_window(window, previous)
        raw = await asyncio.wait_for(
            _call(prompt=prompt, model=self._model),
            timeout=self._timeout,
        )
        return raw.strip()
