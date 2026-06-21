"""``GeminiScheduleMeta`` — 채팅 일정 proposal 의 category/summary 1회 도출.

비용 최우선: digest 요약기와 동일 flash-lite + ``thinking_budget=0``. ``response_schema`` 로
``{category, summary}`` JSON 을 강제한다. 호출/파싱 실패는 빈 메타로 흡수 — 일정 카드 생성을
막지 않는다(메타 없이 항목 생성 → iOS '정리 중' 폴백). 재분석이 아니라 메타 채움만 한다
(DOMAIN_DESIGN §5.2 "재분석 안 함" 유지 — instance 는 채팅 확정값 그대로).

agent prompts 모듈을 import 하지 않고 자체 상수로 둔다(모듈 경계 — conversations 가 agent 에
의존하지 않게. ``gemini_monthly_digest`` 와 동일 방침). category/summary 기준은
``agent/prompts/system_prompts.py`` 의 분석 기준과 같은 취지다(2-8자 명사구 · summary 1-2문장 ·
광범위 버킷 금지).
"""

import asyncio
import json
from functools import lru_cache

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.conversations.domain.ports import ScheduleMeta, ScheduleMetaLLM

logger = structlog.get_logger(__name__)

SCHEDULE_META_SYSTEM = """너는 모찌(MOCHI)다. 사용자가 채팅에서 확정한 '일정' 하나를 받아,
나중에 그 일정을 잘 떠올릴 수 있게 (1) 카테고리(category)와 (2) 한 줄 요약(summary)만 만든다.

이미 사용자가 확정한 일정이다 — 일정 내용·날짜를 바꾸거나 되묻지 말고, 분류용 메타만 만든다.

# summary — 왜 저장했나
- 1~2개의 한국어 문장. 이 일정이 무엇이고 사용자가 왜 챙기려 하는지 담백하게.
- 제목을 그대로 베끼지 말고, 메모 등 맥락을 녹여 "왜"가 드러나게 한다.

# category — 한눈에 묶어볼 라벨
- 짧은 한국어 명사구. 가능하면 2~8자(예: 병원, 데이트, 가족 모임, 자동차 관리, 대학 일정).
- 사용자가 함께 모아볼 만한 기록을 묶는 라벨이고, 사용자에게 그대로 보인다.
- '기존에 자주 쓴 카테고리'가 주어지면, 새 일정이 정말 같은 종류일 때 그 라벨을 재사용해
  달별 흔들림을 줄인다(예: "여행 준비"/"여행 계획" → 기존 "여행").
- 일정·할 일·지식·메모 같은 광범위 버킷으로 뭉개지 않는다. 구체 주제 영역을 우선한다."""

# Vertex 호환 JSON Schema(대문자 Type). google-genai 가 response_schema 로 구조를 강제한다.
_RESPONSE_SCHEMA: dict[str, object] = {
    "type": "OBJECT",
    "properties": {
        "category": {"type": "STRING"},
        "summary": {"type": "STRING"},
    },
    "required": ["category", "summary"],
}

_FIELD_LABELS: dict[str, str] = {
    "title": "제목",
    "date": "날짜",
    "time": "시작 시각",
    "end_date": "종료 날짜",
    "end_time": "종료 시각",
    "person": "관련 인물",
    "note": "메모",
}


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _format_prompt(fields: dict[str, str], known_categories: list[str]) -> str:
    lines = ["# 사용자가 확정한 일정"]
    for key, label in _FIELD_LABELS.items():
        value = (fields.get(key) or "").strip()
        if value:
            lines.append(f"- {label}: {value}")
    if known_categories:
        lines.append("# 기존에 자주 쓴 카테고리 (같은 종류면 재사용)")
        lines.append(", ".join(known_categories))
    return "\n".join(lines)


async def _call(*, prompt: str, model: str) -> str:
    cfg = types.GenerateContentConfig(
        system_instruction=SCHEDULE_META_SYSTEM,
        temperature=0.4,
        max_output_tokens=512,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        response_mime_type="application/json",
        response_schema=_RESPONSE_SCHEMA,
    )
    resp = await _shared_client().aio.models.generate_content(model=model, contents=prompt, config=cfg)
    return resp.text or ""


def _parse(raw: str) -> ScheduleMeta:
    data = json.loads(raw)
    # category 는 사용자-facing 칩 라벨(목표 2-8자) — 비정상 장문 출력이 리스트/칩 UI 를 깨지 않게 클램프.
    category = (str(data.get("category") or "")).strip()[:40] or None
    summary = (str(data.get("summary") or "")).strip() or None
    return ScheduleMeta(category=category, summary=summary)


class GeminiScheduleMeta(ScheduleMetaLLM):
    def __init__(self, model: str | None = None, timeout_seconds: float | None = None):
        settings = get_settings()
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def derive(self, *, fields: dict[str, str], known_categories: list[str]) -> ScheduleMeta:
        prompt = _format_prompt(fields, known_categories)
        try:
            raw = await asyncio.wait_for(_call(prompt=prompt, model=self._model), timeout=self._timeout)
            return _parse(raw)
        except Exception as exc:  # noqa: BLE001 — 도출 실패는 빈 메타로 흡수(일정 카드 생성 유지)
            logger.warning("schedule_meta_llm_failed", error=str(exc))
            return ScheduleMeta()
