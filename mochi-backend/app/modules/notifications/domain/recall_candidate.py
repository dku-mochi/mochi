"""능동 회수 트랙 C — 후보 생성 도메인 (관련/맥락 회수, 1:1 임베딩 ANN).

정본 `journal/proactive-recall/tech-plan.md` §8 P7~P9 / `schema.md`(outbox kind=recall 직행).

트랙 C 는 새 기록 저장·분석이 트리거다 — 새 item(B) 의 임베딩으로 유사한 과거 기록(A)을 ANN 으로
찾아 "지금 맥락과 이어지는 기억"으로 떠올린다. 트랙 A/B 와 달리 plan 없이 `notification_outbox` 로
직행(plan_id NULL, kind=recall)해 기존 발송·반응·landing 파이프라인을 재사용한다.

이 포트는 notification_outbox/embeddings/mochi_items(이 모듈이 raw cosine SQL 로 읽음)만 만진다 —
item 표시필드 하이드레이션은 use case 가 cross-module `MochiItemRepository`(application factory)로 한다.
프레임워크 import 금지(sqlalchemy 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import date, datetime
from uuid import UUID


@dataclass(frozen=True, slots=True)
class RecallCandidate:
    """ANN 이웃 1건 — 새 item 과 가까운 과거 기록(회수 앵커 후보)."""

    item_id: UUID
    score: float  # cosine 유사도 (1.0 - distance)
    summary: str | None
    category: str | None
    channel: str | None


class RecallCandidateRepositoryPort(ABC):
    """트랙 C 후보 생성·게이트가 쓰는 owner-scoped 조회/적재. 단일 KST 전제(가드 날짜는 KST local)."""

    @abstractmethod
    async def find_similar(
        self, *, owner_id: UUID, source_item_id: UUID, min_score: float, limit: int
    ) -> list[RecallCandidate]:
        """source_item 의 임베딩과 가까운 과거 기록(자기·삭제 제외, score>=min_score, score desc).

        임베딩 미설정/미색인이면 0행(자연 degrade). 피드/landing 의 `related` 채움에도 재사용된다.
        """

    @abstractmethod
    async def recent_recall_exists(
        self, *, owner_id: UUID, source_item_id: UUID, since: datetime
    ) -> bool:
        """그 item 을 앵커로 한 회수가 since 이후 이미 있나(pending/sent/deferred) — 재스팸 dedup."""

    @abstractmethod
    async def last_dismissed_for_intent(
        self, *, owner_id: UUID, source_intent_id: UUID | None
    ) -> datetime | None:
        """source_intent 의 직전 dismiss 시각(없으면 None) — dismiss cooldown(plan 경계 넘음)."""

    @abstractmethod
    async def same_day_count(self, *, owner_id: UUID, kst_date: date) -> int:
        """그 KST local date 의 owner pending/sent 발송 카운트 — 하루 cap."""

    @abstractmethod
    async def has_deadline_push_same_day(self, *, owner_id: UUID, kst_date: date) -> bool:
        """그 KST local date 에 owner 의 deadline push 가 있나 — 트랙B 양보."""

    @abstractmethod
    async def insert_recall(
        self,
        *,
        owner_id: UUID,
        source_item_id: UUID,
        source_intent_id: UUID | None,
        fire_at: datetime,
        expires_at: datetime,
        title: str,
        body: str,
        collapse_id: str | None,
    ) -> UUID:
        """회수 1건을 notification_outbox 에 직행 적재(kind=recall, plan_id NULL). event_id 반환."""
