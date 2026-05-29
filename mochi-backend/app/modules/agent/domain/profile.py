"""사용자 개인화 프로필 — agent 의 "사용자 기억".

최근 입력들의 sliding window 에서 도출한 유저 특성 요약(관심사·평소 분류 성향)을
보관하고, 새 입력 분석 시 system prompt 에 주입해 결과를 개인화한다. 쓸수록 좋아진다.

프레임워크 의존 없음 (domain layer).
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol
from uuid import UUID

from app.shared.intent import Intent


@dataclass(frozen=True, slots=True)
class ProfileWindowItem:
    """프로필 요약 입력으로 쓰는 최근 항목 1건.

    raw 캡처 ``text`` 는 의도적으로 제외한다 — 프로필 요약기가 민감 캡처 본문을 LLM 으로
    재전송하지 않도록(PRIVACY 최소전송). AI 추상(``summary``)과 사용자가 직접 적은
    ``user_memo`` 만 사용한다.
    """

    summary: str | None
    intent: Intent
    secondary_intents: tuple[Intent, ...]
    user_memo: str | None


@dataclass(frozen=True, slots=True)
class UserProfile:
    owner_id: UUID
    summary: str
    model_version: str
    items_covered: int          # 마지막 요약 시점의 누적 항목 수 (디바운스 기준)
    refreshed_at: datetime | None = None


class UserProfileStore(Protocol):
    """user_profiles 테이블 outbound port — owner 별 격리."""

    async def get(self, *, owner_id: UUID) -> UserProfile | None: ...
    async def upsert(self, profile: UserProfile) -> None: ...


class UserProfileSummarizer(Protocol):
    """최근 window 를 받아 사용자 특성 요약 텍스트를 생성하는 outbound port (LLM)."""

    async def summarize(
        self, *, window: list[ProfileWindowItem], previous: str | None
    ) -> str: ...
