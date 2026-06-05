"""Repository factory — 외부 모듈(agent worker)이 infrastructure 를 직접 알 필요 없게 한다.

mochi_items.application.queries.make_mochi_item_repository 와 동일 패턴(모듈 경계 유지).
"""

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.ports import PushTokenRepository
from app.modules.notifications.infrastructure.repository import PostgresPushTokenRepository


def make_push_token_repository(session: AsyncSession) -> PushTokenRepository:
    return PostgresPushTokenRepository(session)
