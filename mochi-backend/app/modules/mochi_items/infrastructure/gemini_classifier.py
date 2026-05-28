"""Vertex AI Gemini 기반 ``IntentClassifier`` adapter.

`_workspace/2026-05-25-intent-classification-bench.md` 의 v6 prompt + spec 그대로:
- 모델: Gemini 3.1 Flash Lite (Vertex AI), location=global
- temperature=0.3, max_output_tokens=1024, thinking_budget=0
- response_mime_type="application/json" + response_schema 강제

SDK 자체는 동기 호출이라 ``asyncio.to_thread`` 로 thread pool 에 던지고
``asyncio.wait_for`` 로 timeout 을 건다 (FastAPI event loop blocking 방지).
"""

import asyncio
import json
from functools import lru_cache
from typing import Any

import structlog
from google import genai
from google.genai import types
from pydantic import BaseModel, Field, ValidationError

from app.core.config import get_settings
from app.modules.mochi_items.domain.value_objects import (
    IntentClassification,
    IntentClassificationResult,
)
from app.shared.intent import Intent

logger = structlog.get_logger(__name__)


_SYSTEM_PROMPT = """\
# Context

모찌(MOCHI)는 사용자가 일상에서 마주치는 무언가를 *나중에 다시 보고
싶어서* 빠르게 남기는 기록 도구다. 사용자는 모찌 앱을 따로 열지 않고도
아이폰 뒷면을 두 번 탭하기만 하면 그 순간 보던 화면이 모찌의 기록으로
남는다.

사용자 입장에서 본질은 "스크린샷을 찍었다" 가 아니라 **"무언가를 모찌에
남겼다"** 다. 화면 캡쳐는 우연한 형식이고, 진짜 행위는 "이거 잊지 말고
나중에 다시 보자" 라는 의도의 외부화다.

모찌 내부에서는 이 기록을 4개의 의미 분류 (schedule / todo / knowledge /
memo) 중 하나 이상으로 묶는다. 사용자는 한 화면을 *여러 의도* 때문에
동시에 남기는 경우가 흔하다 — 마우스 상품 페이지를 캡쳐한 사람은 "나중에
사야지" 와 "다른 곳 가격과 비교하자" 두 가지를 동시에 의도할 수 있고,
패션 캡쳐는 "사고 싶다" + "이뻐서 박제" 둘 다일 수 있다. LLM 이 단일
의도로 강제 분류하면 사용자의 실제 의도와 자주 어긋난다.

그래서 모찌는 캡쳐 직후 사용자에게 후보들을 보여주고 본인이 직접 의도(들)을
선택하게 한다. **당신이 만드는 3개의 후보 라벨이 그 선택지가 된다.**

# Objective

이 기록을 통해 사용자가 *나중에 다시 보려는 이유* 로 그럴듯한 시나리오
3개를 펼쳐라. 사용자가 후보를 보고 "아 맞아, 이거랑 이거 둘 다 때문에
저장한 거였지" 라고 즉시 알아챌 수 있어야 한다.

# Style — 라벨 작성

라벨은 사용자가 친구에게 "너 왜 이거 모찌에 남겼어?" 라는 질문에 답할
때 쓸 자연스러운 한국어다. 짧고 구체적인 행동·목적으로. 예시: "회신",
"미용실 예약", "대화 박제", "참고", "자랑", "구매 고민". 두 단어 이상이
더 자연스러우면 그것도 좋다.

시스템 분류 어휘 (todo, memo, knowledge, schedule) 와 일반적인 동작
명사 (저장, 캡쳐, 분류, 처리, 후속 작업) 는 라벨에 쓰지 않는다. 사용자는
모찌의 분류 체계를 모르므로 그런 단어를 보면 자기가 무엇을 고르는 건지
알 수 없다.

다만 사용자의 의도 자체가 진짜로 일반적인 동사 ("참고", "기록" 등) 인
경우 — 예컨대 정서적 박제처럼 저장 행위 자체가 목적인 케이스 — 그 단어가
가장 정확한 라벨이다. 무리하게 구체화하지 말 것. "그냥 참고용" 의도를
"기술 공부" 로 specific 하게 만들면 사용자 머릿속 어휘와 어긋난다.

# Audience

한국어 사용자. 모찌의 내부 도메인 어휘를 모른다. 본인의 행동·의도를
한 단어로 표현하는 게 인지 부담이 가장 낮다.

# Task — 후보 셋의 구성

세 후보는 *의미적으로 구별되는 의도* 여야 한다. 같은 4-Intent 매핑이라도
사용자 행동이 다르면 별개 후보로 둔다 (예: "회신" 과 "연락처 저장" 은
둘 다 todo 매핑이지만 사용자 행동이 다르므로 별개). 두 후보가 사실상 같은
행동의 약한 변형이면 한쪽을 더 먼 시나리오로 대체한다.

좁게 해석하지 않는다. 사람이 같은 화면을 모찌에 남기는 동기는 의외로
여러 차원에 걸쳐 있다 — 자기 참고용, 누군가에게 공유, 자랑/추억, 일정
등록, 행동 트리거, 정보 영구 보관 등. 세 후보가 한 차원에 몰리면 다른
차원도 한 자리 잡게 한다.

각 후보의 4-Intent 매핑은 다음 정의에 따른다:
- schedule: 특정 시점에 발생/참여하는 사건 (약속, 마감일, 행사)
- todo: 사용자가 직접 수행해야 할 행동 (구매, 답장, 신청, 시도)
- knowledge: 영구 참조 가치의 정보 (개념, 가이드, 학습)
- memo: 위 셋에 안 들어가는 정서적·일회적 기록 (영감, 추억, 자랑, 분위기)

# applicability — 각 후보의 독립 적용 강도

applicability 는 *그 후보가 사용자의 의도일 가능성* 을 0.0-1.0 으로
독립 표현한다. 진짜 확률이 아니다 — "이 의도가 이 기록에 얼마나 잘 들어맞는가"
라는 적용 강도다. 세 후보 합이 1.0 일 필요 없다. 같은 캡쳐가 여러 의도에
동시에 들어맞을 수 있기 때문이다.

기준:
- 0.85-1.0: 화면 증거가 이 의도를 강하게 지지함. 거의 확실히 사용자
  의도 중 하나.
- 0.5-0.8: 합리적 시나리오. 다른 후보와 동시 적용도 자연스럽다.
- 0.2-0.5: 가능하지만 확신은 낮음. 사용자만 알 수 있는 영역.
- 0.0-0.2: 거의 해당 안 됨 — 굳이 후보로 넣지 말 것.

본질적으로 모호한 케이스 (사용자만 답할 수 있는 경우) 는 비슷한 중간값으로
분산한다. 가짜 확신을 만들지 않는 게 모찌가 사용자에게 잘 묻기 위한
가장 가치 있는 신호다.

분기 신호 (silent / multi-select / 모호 fallback) 는 서버에서 applicability
값으로 후처리하므로 당신이 boolean 을 판단하지 않는다. 점수만 정직하게 박으면 된다.

reasoning 은 한 줄로, 왜 이 시나리오가 이 기록에서 그럴듯한지.

# Response — JSON 출력 형식

다음 형식의 JSON 만 반환한다. 다른 텍스트 없이.

```json
{
  "candidates": [
    {
      "label": "구매 고민",
      "intent": "todo",
      "applicability": 0.85,
      "reasoning": "상품 정보와 가격이 명시되어 있어 구매를 고려 중일 가능성이 가장 높음."
    },
    {
      "label": "가격 비교",
      "intent": "knowledge",
      "applicability": 0.65,
      "reasoning": "다른 매장과 비교하기 위한 참고 자료로 활용하려는 의도도 자연스러움."
    },
    {
      "label": "위시리스트",
      "intent": "memo",
      "applicability": 0.40,
      "reasoning": "지인 선물 후보로 저장해두는 경우도 가능."
    }
  ]
}
```
"""

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "intent": {
                        "type": "string",
                        "enum": ["schedule", "todo", "knowledge", "memo"],
                    },
                    "applicability": {"type": "number"},
                    "reasoning": {"type": "string"},
                },
                "required": ["label", "intent", "applicability", "reasoning"],
            },
        },
    },
    "required": ["candidates"],
}

_USER_PROMPT = "이 기록에 대한 use case 후보 3개를 생성하세요.\nJSON 만 응답.\n"


class _CandidateModel(BaseModel):
    """LLM 응답 후보 1개의 Pydantic 검증 모델."""

    label: str = Field(min_length=1)
    intent: Intent
    applicability: float = Field(ge=0.0, le=1.0)
    reasoning: str


class _ResponseModel(BaseModel):
    candidates: list[_CandidateModel] = Field(min_length=3, max_length=3)


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_intent_location,
    )


def _call_sync(*, image: bytes, mime: str, model: str) -> str:
    cfg = types.GenerateContentConfig(
        system_instruction=_SYSTEM_PROMPT,
        temperature=0.3,
        max_output_tokens=1024,
        response_mime_type="application/json",
        response_schema=_RESPONSE_SCHEMA,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    part = types.Part.from_bytes(data=image, mime_type=mime)
    resp = _shared_client().models.generate_content(
        model=model,
        contents=[part, _USER_PROMPT],
        config=cfg,
    )
    return resp.text or ""


class VertexAIGeminiClassifier:
    """Vertex AI Gemini 기반 분류 어댑터 (``IntentClassifier`` 구현체).

    timeout 은 기본적으로 ``Settings.agent_step_timeout_seconds`` 를 재사용한다.
    Gemini 호출이 timeout 을 넘으면 ``TimeoutError`` 가 그대로 전파된다.
    """

    def __init__(self, model: str | None = None, timeout_seconds: float | None = None):
        settings = get_settings()
        self._model = model or settings.gemini_intent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def classify(self, *, image: bytes, mime: str) -> IntentClassificationResult:
        if mime not in ("image/jpeg", "image/png"):
            raise ValueError(f"Unsupported mime type for intent classification: {mime}")
        if not image:
            raise ValueError("image bytes must be non-empty")

        raw = await asyncio.wait_for(
            asyncio.to_thread(_call_sync, image=image, mime=mime, model=self._model),
            timeout=self._timeout,
        )

        try:
            parsed = _ResponseModel.model_validate_json(raw)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.error(
                "gemini.classify.parse_error",
                model=self._model,
                raw_prefix=raw[:200],
            )
            raise ValueError("Gemini classifier returned malformed response") from exc

        return IntentClassificationResult(
            candidates=tuple(
                IntentClassification(
                    label=c.label,
                    intent=c.intent,
                    applicability=c.applicability,
                    reasoning=c.reasoning,
                )
                for c in parsed.candidates
            ),
        )
