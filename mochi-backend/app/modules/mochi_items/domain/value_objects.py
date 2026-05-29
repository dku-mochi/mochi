"""MochiItem 분류에 관한 value objects.

LLM(Vertex AI Gemini)이 한 캡쳐에 대해 출력하는 사용자 의도 후보(``IntentClassification``).
``applicability`` 는 실제 확률이 아니라 "이 의도가 이 기록에 얼마나 잘 들어맞는가" 의 독립
강도다 (0.0-1.0). 후보 간 합이 1.0 일 필요 없다.

primary/secondary/confidence 도출은 worker(``AgentOrchestrator._to_analysis_result``)가
candidates 의 applicability 분포에서 수행한다 — confidence := 최상위 후보 applicability.
"""

from dataclasses import dataclass

from app.shared.intent import Intent


@dataclass(frozen=True, slots=True)
class IntentClassification:
    """LLM 이 출력한 단일 후보 (홈 "헷갈려요" 카드·Live Activity 버튼의 원천).

    - ``label``: 사용자가 보게 될 한국어 라벨 (예: "구매 고민", "회신").
    - ``intent``: 해당 라벨의 4-Intent 매핑.
    - ``applicability``: 0.0-1.0. 적용 강도.
    - ``reasoning``: 한 줄 — 왜 이 시나리오가 그럴듯한지.
    """

    label: str
    intent: Intent
    applicability: float
    reasoning: str = ""

    def __post_init__(self) -> None:
        if not self.label.strip():
            raise ValueError("IntentClassification.label must be non-empty")
        if not 0.0 <= self.applicability <= 1.0:
            raise ValueError(
                f"IntentClassification.applicability must be in [0, 1], got {self.applicability}"
            )
