"""버전 관리되는 시스템 프롬프트.

각 프롬프트는 다음 메타데이터와 함께 관리된다:
- ``model_target``: 호환되는 모델 (예: gemini-3.5-flash)
- ``eval_dataset_version``: 회귀 테스트 데이터셋 식별자
- ``changelog``: 변경 요약·시점·이유

프롬프트를 수정할 때는 새 버전 상수를 추가하고 changelog 라인을 남긴다.
기존 버전은 그대로 두어 eval/회귀 테스트가 깨지지 않게 한다.
"""

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True, slots=True)
class PromptVersion:
    name: str
    body: str
    model_target: str
    eval_dataset_version: str
    revised_on: date
    rationale: str


CLASSIFY_AND_ACT_V1 = PromptVersion(
    name="classify_and_act@v1",
    body=(
        "You are MOCHI — an agent that organizes screenshots, links, and short notes into 4 intents.\n\n"
        "Intents:\n"
        "- schedule   (events with a clear date/time)\n"
        "- todo       (concrete actionable items)\n"
        "- knowledge  (durable learning material)\n"
        "- memo       (everything else / personal logs)\n\n"
        "For each input you must call exactly one tool: `multimodalAnalyze`.\n"
        "You may additionally call `webFetch` if a URL is provided and the page must be fetched to ground intent.\n"
        "You may call `embed` once you have the final summary.\n\n"
        "Output the JSON conforming to `MultimodalAnalyzeOutput`. Be strict about types.\n"
        "Always set `confidence` based on signal density. A user-supplied memo raises confidence."
    ),
    model_target="gemini-3.5-flash",
    eval_dataset_version="capture-classify-v1@2026-05-22",
    revised_on=date(2026, 5, 22),
    rationale="Initial 4-intent classifier prompt aligned with backend tool registry.",
)


ACTIVE_PROMPT: PromptVersion = CLASSIFY_AND_ACT_V1
