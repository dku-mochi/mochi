"""알림 페이지 "지난 알림" 조회 유스케이스 — owner 의 이미 보낸 알림 목록.

`get_upcoming_notifications` 와 같은 형태 — title/body 가 outbox 에 이미 렌더돼 있어
cross-module 하이드레이션 없이 이 모듈 포트 하나로 entry 가 완성된다.
"""

from dataclasses import dataclass
from uuid import UUID

from app.modules.notifications.domain.sent_feed import (
    SentFeedRepositoryPort,
    SentNotification,
)


@dataclass(slots=True)
class GetSentNotifications:
    """owner 의 발송 완료 알림(status='sent')을 sent_at 내림차순으로 반환."""

    feed: SentFeedRepositoryPort

    async def execute(self, *, owner_id: UUID, limit: int) -> list[SentNotification]:
        return await self.feed.list_sent(owner_id=owner_id, limit=limit)
