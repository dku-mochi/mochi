"""Agent 분석 결과의 도메인 표현 (2026-06-04 빅뱅).

LLM(`GeminiAgentClient`)이 ``finalizeAnalysis`` 로 저술한 구조화 출력
(``MultimodalAnalyzeOutput``, pydantic)을 orchestrator 가 이 순수 도메인 값으로
변환해 ``MochiItemGateway.apply_analysis`` 에 넘긴다. 프레임워크 의존 없음.

LLM 이 저장할 ``intent_instances`` · ``needs_review`` · ``review_options`` 를 직접 낸다 —
점수(applicability)·대표(primary)·confidence derive 는 폐기됐다.
"""

from dataclasses import dataclass

from app.modules.mochi_items.domain.value_objects import IntentInstance, ReviewOption


@dataclass(frozen=True, slots=True)
class ExtractedEntity:
    kind: str
    value: str


@dataclass(frozen=True, slots=True)
class AnalysisResult:
    """한 MochiItem 의 분석 완료 산출물.

    - ``intent_instances``: 저장할 것만(곧 active). 같은 type 다중 허용.
    - ``needs_review``: LLM holistic boolean.
    - ``review_options``: needs_review 일 때의 미확정 후보(mochi_items JSONB 영속 — PR-B).
    """

    summary: str
    needs_review: bool = False
    intent_instances: tuple[IntentInstance, ...] = ()
    review_options: tuple[ReviewOption, ...] = ()
    importance: int = 3
    model_version: str = ""
    entities: tuple[ExtractedEntity, ...] = ()
