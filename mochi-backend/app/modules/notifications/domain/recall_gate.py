"""트랙 C LLM 선별 게이트 도메인 — 포트 + 입출력 (2026-06-17).

정본 `journal/proactive-recall/track-c-llm-gate-decision.md`.

ANN overfetch → 얇은 필터(archived·근중복)를 통과한 후보 N건을 LLM 이 보고 "다시 볼 가치 있는 1건"을
고르거나(recall=false) 아무것도 안 고른다. 코사인은 판별자가 아니라 후보 추림용 바닥값일 뿐 —
선별·작문은 LLM 이 한다(같은 결정 재등장 vs 단순 토픽 유사 구분, 한국어 회수 메시지 작성).

프레임워크 import 금지(genai 는 infrastructure 어댑터 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True, slots=True)
class RecallGateCandidate:
    """게이트에 넘기는 과거 기록 후보 1건(앵커 후보). index 는 LLM chosen_index 매칭용."""

    index: int
    item_id: UUID
    title: str
    summary: str | None
    intent_types: tuple[str, ...]
    gap_days: float  # 트리거 B 대비 이 후보가 얼마나 오래된 기록인지
    score: float  # cosine 유사도(추림 바닥값, 판별자 아님)


@dataclass(frozen=True, slots=True)
class RecallGateInput:
    """LLM 게이트 입력 — 방금 저장한 B + 후보 N건."""

    trigger_title: str
    trigger_summary: str | None
    trigger_types: tuple[str, ...]
    candidates: tuple[RecallGateCandidate, ...]


@dataclass(frozen=True, slots=True)
class RecallGateDecision:
    """LLM 게이트 출력. recall=False 면 발송 안 함(나머지 필드 무의미)."""

    recall: bool
    chosen_index: int | None
    relation: str  # comparison|followup|reference|none (내부 라벨 — 메시지엔 안 들어감)
    confidence: float
    message: str  # 한국어 회수 카피 (recall=True 시)
    reason: str


class RecallGatePort(ABC):
    """후보 N건 → 회수 결정 0~1건. best-effort(예외는 호출부가 skip 처리)."""

    @abstractmethod
    async def decide(self, *, gate_input: RecallGateInput) -> RecallGateDecision: ...
