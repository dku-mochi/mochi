"""Repository factory — 외부 모듈(agent worker)이 infrastructure 를 직접 알 필요 없게 한다.

mochi_items.application.queries.make_mochi_item_repository 와 동일 패턴(모듈 경계 유지).
"""

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.ports import PushTokenRepository
from app.modules.notifications.domain.upcoming_feed import UpcomingFeedRepositoryPort
from app.modules.notifications.infrastructure.repository import PostgresPushTokenRepository
from app.modules.notifications.infrastructure.upcoming_feed_repository import (
    PostgresUpcomingFeedRepository,
)


def make_push_token_repository(session: AsyncSession) -> PushTokenRepository:
    return PostgresPushTokenRepository(session)


def make_upcoming_feed_repository(session: AsyncSession) -> UpcomingFeedRepositoryPort:
    """채팅(conversations)이 notifications.infrastructure 를 직접 알지 않고 예정 알림을 읽게 하는 진입점.

    채팅 read 툴(`list_notifications`)·propose 검증이 이 팩토리 + `GetUpcomingNotifications`
    유스케이스로 조립한다(cross-module 진입은 application 까지 — ARCHITECTURE §3.3).
    """
    return PostgresUpcomingFeedRepository(session)
