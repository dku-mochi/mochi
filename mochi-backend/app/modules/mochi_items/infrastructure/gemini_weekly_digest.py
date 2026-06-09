"""`WeeklyDigestLLM` 구현 — Gemini structured-output 1회 호출.

비용 최우선: 프로필 요약기와 동일 flash-lite + ``thinking_budget=0``. ``response_schema`` 로
greeting + 카테고리 재그룹핑을 JSON 으로 강제한다. 파싱/호출 실패는 graceful 폴백(빈 그룹·빈
greeting)으로 application 의 정적 폴백에 위임 — 500 을 던지지 않는다.
"""

import asyncio
import json
from functools import lru_cache

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.mochi_items.domain.digest_port import (
    CategoryGroup,
    DigestInputItem,
    WeeklyDigestLLM,
    WeeklyDigestLLMResult,
)

logger = structlog.get_logger(__name__)

# agent prompts 모듈을 import 하지 않고 자체 상수로 둔다(모듈 경계 — mochi_items 가 agent 에 의존하지 않게).
WEEKLY_DIGEST_SYSTEM = """너는 모찌(MOCHI)다. 사용자가 한 주 동안 모은 기록들을 보고,
(1) 먼저 말을 거는 따뜻한 한마디(greeting)와 (2) 비슷한 주제끼리 묶은 카테고리 그룹을 만든다.

# greeting — 모찌의 한마디
- 정확히 한 문장. 한국어.
- 그 주에 사용자가 무엇에 관심 가졌는지를 다정하게 짚어 준다. 모찌가 먼저 챙겨 주는 말투.
- "12개를 저장했어요" 같은 숫자·통계 나열 금지. 친구에게 건네듯 담백하고 따뜻하게.
- 일정/할 일/학습/기록/todo/schedule 같은 분류 용어를 절대 쓰지 않는다.
- 이모지·느낌표 남발 금지.

# category_groups — 카테고리 재그룹핑(정규화)
- 입력으로 그 주에 등장한 카테고리(fine)들과 대표 내용을 받는다.
- 목적은 항목마다 제각각 생긴 카테고리(예: "여행 준비", "여행 계획", "여행")를 같은 의미면
  하나의 coarse 라벨("여행")로 통합해 파편화를 줄이는 것이다. "짧게 만들기"가 목적이 아니다.
- "기존에 자주 쓴 카테고리"가 주어지면, 새 fine 을 가능한 그 라벨로 흡수해 주별 흔들림을 줄인다.
- 규칙:
  - 의미가 다른 관심사를 억지로 한 그룹에 넣지 않는다(모든 걸 "기타"로 뭉개기 금지).
  - 한 fine 은 정확히 한 coarse 에만 속한다(중복 금지).
  - fine 이 한두 개뿐인 작은 주제는 그 자체를 coarse 로 둬도 된다(억지 상위어 금지).
  - 입력에 없는 fine 을 지어내지 않는다. 받은 fine 문자열을 그대로 fines 배열에 echo 한다.
  - coarse 는 사용자가 한눈에 알아볼 짧은 한국어 명사.
- 항목 id 나 제목은 출력하지 않는다. coarse 라벨과 fines(원문 그대로)만 낸다."""

# Vertex 호환 JSON Schema(대문자 Type). google-genai 가 response_schema 로 받아 구조를 강제한다.
_RESPONSE_SCHEMA: dict[str, object] = {
    "type": "OBJECT",
    "properties": {
        "greeting": {"type": "STRING"},
        "category_groups": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "coarse": {"type": "STRING"},
                    "fines": {"type": "ARRAY", "items": {"type": "STRING"}},
                },
                "required": ["coarse", "fines"],
            },
        },
    },
    "required": ["greeting", "category_groups"],
}


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _format_prompt(items: list[DigestInputItem], item_count: int, known_categories: list[str]) -> str:
    lines = [f"# 이번 주 모은 기록 (총 {item_count}개)"]
    if known_categories:
        lines.append("# 기존에 자주 쓴 카테고리 (가능하면 재사용)")
        lines.append(", ".join(known_categories))
    lines.append("# 등장한 카테고리와 대표 내용")
    for it in items:
        category = it.category or "미분류"
        body = (it.title or "").strip().replace("\n", " ")
        lines.append(f"- [{category}] {body[:80]}")
    return "\n".join(lines)


async def _call(*, prompt: str, model: str) -> str:
    cfg = types.GenerateContentConfig(
        system_instruction=WEEKLY_DIGEST_SYSTEM,
        temperature=0.5,
        max_output_tokens=1024,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        response_mime_type="application/json",
        response_schema=_RESPONSE_SCHEMA,
    )
    resp = await _shared_client().aio.models.generate_content(model=model, contents=[prompt], config=cfg)
    return resp.text or ""


def _parse(raw: str) -> WeeklyDigestLLMResult:
    data = json.loads(raw)
    greeting = (data.get("greeting") or "").strip()
    groups = tuple(
        CategoryGroup(
            coarse=str(g["coarse"]).strip(),
            fines=tuple(str(f).strip() for f in g.get("fines", []) if str(f).strip()),
        )
        for g in data.get("category_groups", [])
        if g.get("coarse")
    )
    return WeeklyDigestLLMResult(greeting=greeting, category_groups=groups)


class GeminiWeeklyDigest(WeeklyDigestLLM):
    def __init__(self, model: str | None = None, timeout_seconds: float | None = None):
        settings = get_settings()
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def generate(
        self,
        *,
        items: list[DigestInputItem],
        item_count: int,
        known_categories: list[str],
    ) -> WeeklyDigestLLMResult:
        prompt = _format_prompt(items, item_count, known_categories)
        try:
            raw = await asyncio.wait_for(_call(prompt=prompt, model=self._model), timeout=self._timeout)
            return _parse(raw)
        except Exception as exc:  # noqa: BLE001 — LLM 실패는 정적 폴백으로 흡수(500 회피)
            logger.warning("weekly_digest_llm_failed", error=str(exc))
            return WeeklyDigestLLMResult(greeting="", category_groups=())
