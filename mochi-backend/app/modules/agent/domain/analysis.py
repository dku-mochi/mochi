"""Agent 분석 결과의 도메인 표현.

LLM(`GeminiAgentClient`)이 ``finalizeAnalysis`` 로 저술한 구조화 출력
(``MultimodalAnalyzeOutput``, pydantic)을 orchestrator 가 이 순수 도메인 값으로
변환해 ``MochiItemGateway.apply_analysis`` 에 넘긴다. 프레임워크 의존 없음.

LLM 은 use case 후보 셋(``candidates``)과 각 후보의 applicability 만 정직하게 매긴다.
primary intent / confidence / secondary_intents 는 orchestrator 가 applicability 분포에서
derive 한다 — confidence := 최상위 후보 applicability (단일 원천).
"""

from dataclasses import dataclass, field

from app.shared.intent import Intent


@dataclass(frozen=True, slots=True)
class ExtractedEntity:
    kind: str
    value: str


@dataclass(frozen=True, slots=True)
class AnalysisCandidate:
    """LLM 이 펼친 use case 후보 1개 — 홈 "헷갈려요" 카드·Live Activity 버튼의 원천.

    - ``label``: 사용자가 보게 될 한국어 라벨 (예: "구매 고민", "회신").
    - ``intent``: 해당 라벨의 4-Intent 매핑.
    - ``applicability``: 0.0-1.0. "이 의도가 이 기록에 얼마나 잘 들어맞는가" 의 독립 강도.
    - ``reasoning``: 한 줄 — 왜 이 시나리오가 그럴듯한지.
    """

    label: str
    intent: Intent
    applicability: float
    reasoning: str = ""


@dataclass(frozen=True, slots=True)
class AnalysisResult:
    """한 MochiItem 의 분석 완료 산출물.

    ``intent`` / ``confidence`` / ``secondary_intents`` / ``intent_applicability`` 는
    모두 ``candidates`` 의 applicability 에서 derive 된 값이다 (orchestrator 가 계산).
    """

    intent: Intent
    summary: str
    confidence: float
    secondary_intents: tuple[Intent, ...] = ()
    intent_applicability: dict[Intent, float] = field(default_factory=dict)
    importance: int = 3
    model_version: str = ""
    entities: tuple[ExtractedEntity, ...] = ()
    candidates: tuple[AnalysisCandidate, ...] = ()
