"""Capture 분류에 관한 value objects.

LLM (Vertex AI Gemini) 이 한 캡쳐에 대해 출력하는 사용자 의도 후보 셋과,
그것으로부터 primary/secondary intent + intent별 적용 강도 (applicability) 를
도출하는 로직.

``applicability`` 는 실제 확률이 아니라 "이 의도가 이 기록에 얼마나 잘 들어맞는가"
의 독립 강도다 (0.0-1.0). 후보 간 합이 1.0 일 필요 없다.
"""

from collections.abc import Mapping
from dataclasses import dataclass

from app.shared.intent import Intent


@dataclass(frozen=True, slots=True)
class IntentClassification:
    """LLM 이 출력한 단일 후보.

    - ``label``: 사용자가 보게 될 한국어 라벨 (예: "구매 고민", "회신").
    - ``intent``: 해당 라벨의 4-Intent 매핑.
    - ``applicability``: 0.0-1.0. ``IntentClassificationResult`` 의 invariant 가 강제한다.
    - ``reasoning``: 한 줄 — 왜 이 시나리오가 그럴듯한지.
    """

    label: str
    intent: Intent
    applicability: float
    reasoning: str

    def __post_init__(self) -> None:
        if not self.label.strip():
            raise ValueError("IntentClassification.label must be non-empty")
        if not 0.0 <= self.applicability <= 1.0:
            raise ValueError(
                f"IntentClassification.applicability must be in [0, 1], got {self.applicability}"
            )


@dataclass(frozen=True, slots=True)
class IntentClassificationResult:
    """후보 3개로 구성된 LLM 분류 결과.

    `Capture.from_classification` 이 이 값으로부터 primary/secondary/applicability
    를 결정한다.
    """

    candidates: tuple[IntentClassification, ...]

    def __post_init__(self) -> None:
        if len(self.candidates) != 3:
            raise ValueError(
                f"IntentClassificationResult requires exactly 3 candidates, got {len(self.candidates)}"
            )

    @property
    def primary_intent(self) -> Intent:
        """가장 높은 applicability 를 가진 후보의 intent. 동률 시 입력 순서가 빠른 쪽."""
        # max() 는 비교에서 안정 정렬이라 입력 순서를 자연스럽게 따라간다.
        return max(self.candidates, key=lambda c: c.applicability).intent

    @property
    def secondary_intents(self) -> tuple[Intent, ...]:
        """primary 를 제외한 distinct intent 들 — applicability 내림차순.

        같은 intent 가 두 후보에 걸쳐 나오면 처음 만난 (= 더 높은 applicability) 것만 남긴다.
        """
        primary = self.primary_intent
        seen: set[Intent] = {primary}
        ordered: list[Intent] = []
        for c in sorted(self.candidates, key=lambda c: c.applicability, reverse=True):
            if c.intent in seen:
                continue
            ordered.append(c.intent)
            seen.add(c.intent)
        return tuple(ordered)

    @property
    def applicability_map(self) -> Mapping[Intent, float]:
        """Intent → applicability. 같은 intent 가 여러 후보에 나오면 최댓값을 채택.

        후보에 등장하지 않은 intent 는 키에 포함되지 않는다 ("측정 안 됨" ≠ "0점").
        후보가 명시적으로 applicability=0.0 으로 등장한 경우는 그대로 0.0 으로 보존된다.
        """
        result: dict[Intent, float] = {}
        for c in self.candidates:
            if c.intent not in result or c.applicability > result[c.intent]:
                result[c.intent] = c.applicability
        return result
