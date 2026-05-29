"""`UserProfileStore` 구현 — user_profiles 테이블 (owner 별 1행).

raw SQL 을 쓰는 이유: 테이블 ORM 정의를 두면 ``agent.infrastructure`` 가 다른 모듈의
ORM 을 참조하거나 중복 정의해야 하는데, ``AgentRunPersistence`` 와 동일하게 raw SQL
을 쓰면 그 결합을 피할 수 있다. 테이블 자체는 alembic 0007 이 만든다.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.agent.domain.profile import UserProfile, UserProfileStore


class PostgresUserProfileStore(UserProfileStore):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def get(self, *, owner_id: UUID) -> UserProfile | None:
        row = (
            await self._session.execute(
                text(
                    "SELECT owner_id, summary, model_version, items_covered, refreshed_at "
                    "FROM user_profiles WHERE owner_id = :owner_id"
                ),
                {"owner_id": owner_id},
            )
        ).one_or_none()
        if row is None:
            return None
        return UserProfile(
            owner_id=row.owner_id,
            summary=row.summary,
            model_version=row.model_version,
            items_covered=row.items_covered,
            refreshed_at=row.refreshed_at,
        )

    async def upsert(self, profile: UserProfile) -> None:
        # flush 만 — 트랜잭션 commit 은 호출자(worker)가 분석/outbox 와 함께 한 번에 한다.
        await self._session.execute(
            text(
                """
                INSERT INTO user_profiles
                    (owner_id, summary, model_version, items_covered, refreshed_at)
                VALUES (:owner_id, :summary, :model_version, :items_covered, :refreshed_at)
                ON CONFLICT (owner_id) DO UPDATE SET
                    summary = EXCLUDED.summary,
                    model_version = EXCLUDED.model_version,
                    items_covered = EXCLUDED.items_covered,
                    refreshed_at = EXCLUDED.refreshed_at
                """
            ),
            {
                "owner_id": profile.owner_id,
                "summary": profile.summary,
                "model_version": profile.model_version,
                "items_covered": profile.items_covered,
                "refreshed_at": profile.refreshed_at or datetime.utcnow(),
            },
        )
