"""다가오는 예정 알림 조회 — `UpcomingFeedRepositoryPort` 구현. 읽기 전용 단순 SELECT.

이 모듈 소유 테이블(notification_outbox/plan)만 만진다. title/body 는 outbox 에 이미 렌더돼
있어 cross-module 하이드레이션 불필요(get_recall_feed 와 다름).
"""

from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.upcoming_feed import (
    UpcomingFeedRepositoryPort,
    UpcomingNotification,
)
from app.modules.notifications.infrastructure.orm import (
    NotificationOutboxRow,
    NotificationPlanRow,
)

# 홈 "예정 알림" 범위 — 마감/일정(deadline)·주기 넛지(nudge) + 미래 예약 회수(spaced).
# spaced 는 RecallHero(식어가는 지식 in-app 회수)와 별개로 "모찌가 앞으로 보낼 예약 알림"이라
# 예정 탭에 노출(2026-06-21). recall(트랙C 즉시발송)은 pending 미래로 머물지 않아 자연 제외.
_UPCOMING_KINDS = ("deadline", "nudge", "spaced")


class PostgresUpcomingFeedRepository(UpcomingFeedRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def list_upcoming(self, *, owner_id: UUID, limit: int) -> list[UpcomingNotification]:
        # pending + 미래(fire_at>now) + 마감/일정/회수. active plan 조인으로 cancel 된 plan 잔여 배제.
        # deadline/nudge/spaced 모두 plan 기반(plan_id NOT NULL)이라 inner join 이 자연스럽다.
        stmt = (
            select(
                NotificationOutboxRow.event_id,
                NotificationOutboxRow.kind,
                NotificationOutboxRow.fire_at,
                NotificationOutboxRow.title,
                NotificationOutboxRow.body,
                NotificationOutboxRow.original_fire_at,
                NotificationOutboxRow.source_item_id,
                NotificationOutboxRow.source_intent_id,
            )
            .join(
                NotificationPlanRow,
                NotificationOutboxRow.plan_id == NotificationPlanRow.id,
            )
            .where(
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "pending",
                NotificationOutboxRow.kind.in_(_UPCOMING_KINDS),
                NotificationOutboxRow.fire_at > func.now(),
                NotificationPlanRow.status == "active",
            )
            .order_by(NotificationOutboxRow.fire_at)
            .limit(limit)
        )
        rows = (await self._session.execute(stmt)).all()
        return [
            UpcomingNotification(
                event_id=row.event_id,
                kind=row.kind,
                fire_at=row.fire_at,
                title=row.title,
                body=row.body,
                original_fire_at=row.original_fire_at,
                item_id=row.source_item_id,
                intent_id=row.source_intent_id,
            )
            for row in rows
        ]
