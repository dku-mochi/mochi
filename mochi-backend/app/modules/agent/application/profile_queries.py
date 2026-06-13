"""사용자 프로필 read 진입점 — 다른 모듈(채팅 등)이 application 레이어로만 접근하도록 노출한다.

모듈 경계(②티어): conversations 는 agent 의 ``infrastructure`` 를 직접 import 할 수 없다.
프로필 store 구현체 결합을 이 함수 뒤로 숨겨 conversations 가 application 만 의존하게 한다.
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.agent.infrastructure.profile_store import PostgresUserProfileStore


async def load_chat_profile(session: AsyncSession, owner_id: UUID) -> str | None:
    """채팅용 페르소나 프로필(chat_summary) — 없으면 None."""
    profile = await PostgresUserProfileStore(session).get(owner_id=owner_id)
    return profile.chat_summary if profile else None
