"""Agent 분석 결과의 도메인 표현.

LLM(`GeminiAgentClient`)이 ``finalizeAnalysis`` 로 저술한 구조화 출력
(``MultimodalAnalyzeOutput``, pydantic)을 orchestrator 가 이 순수 도메인 값으로
변환해 ``MochiItemGateway.apply_analysis`` 에 넘긴다. 프레임워크 의존 없음.
"""

from dataclasses import dataclass, field

from app.shared.intent import Intent


@dataclass(frozen=True, slots=True)
class ExtractedEntity:
    kind: str
    value: str


@dataclass(frozen=True, slots=True)
class AnalysisResult:
    """한 MochiItem 의 분석 완료 산출물."""

    intent: Intent
    summary: str
    confidence: float
    secondary_intents: tuple[Intent, ...] = ()
    intent_applicability: dict[Intent, float] = field(default_factory=dict)
    importance: int = 3
    model_version: str = ""
    entities: tuple[ExtractedEntity, ...] = ()
