"""이미 보낸 알림 조회 — `SentFeedRepositoryPort` 구현. 읽기 전용 단순 SELECT.

이 모듈 소유 테이블(notification_outbox)만 만진다. title/body 는 outbox 에 이미 렌더돼 있어
cross-module 하이드레이션 불필요. plan 무관(recall 직행 sent 도 포함)이라 join 없이 outbox 만.
"""

from uuid import UUID

from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.sent_feed import (
    SentFeedRepositoryPort,
    SentNotification,
)
from app.modules.notifications.infrastructure.orm import NotificationOutboxRow


class PostgresSentFeedRepository(SentFeedRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def list_sent(
        self, *, owner_id: UUID, limit: int
    ) -> list[SentNotification]:
        # status='sent' 전부(종류 무관). sent_at 내림차순(최근 받은 것 먼저).
        stmt = (
            select(
                NotificationOutboxRow.event_id,
                NotificationOutboxRow.kind,
                NotificationOutboxRow.sent_at,
                NotificationOutboxRow.opened_at,
                NotificationOutboxRow.dismissed_at,
                NotificationOutboxRow.title,
                NotificationOutboxRow.body,
                NotificationOutboxRow.source_item_id,
                NotificationOutboxRow.source_intent_id,
            )
            .where(
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "sent",
            )
            .order_by(desc(NotificationOutboxRow.sent_at))
            .limit(limit)
        )
        rows = (await self._session.execute(stmt)).all()
        result: list[SentNotification] = []
        for row in rows:
            # status='sent' 면 sent_at 은 항상 채워져 있으나, 타입 안전을 위해 방어.
            if row.sent_at is None:
                continue
            result.append(
                SentNotification(
                    event_id=row.event_id,
                    kind=row.kind,
                    sent_at=row.sent_at,
                    opened_at=row.opened_at,
                    dismissed_at=row.dismissed_at,
                    title=row.title,
                    body=row.body,
                    item_id=row.source_item_id,
                    intent_id=row.source_intent_id,
                )
            )
        return result
