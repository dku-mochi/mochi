"""홈탭 "예정 알림" 조회(A) 유스케이스 — owner 의 다가오는 발송 예정 알림 목록.

`get_recall_feed` 와 달리 cross-module 하이드레이션이 **없다** — title/body 가 outbox 에 이미
렌더돼 있어(worker `_render_content`), 이 모듈 포트 하나만으로 entry 가 완성된다.
"""

from dataclasses import dataclass
from uuid import UUID

from app.modules.notifications.domain.upcoming_feed import (
    UpcomingFeedRepositoryPort,
    UpcomingNotification,
)


@dataclass(slots=True)
class GetUpcomingNotifications:
    """owner 의 pending 미래 알림(마감/일정 + 예약 회수 spaced)을 fire_at 오름차순으로 반환."""

    feed: UpcomingFeedRepositoryPort

    async def execute(self, *, owner_id: UUID, limit: int) -> list[UpcomingNotification]:
        return await self.feed.list_upcoming(owner_id=owner_id, limit=limit)
