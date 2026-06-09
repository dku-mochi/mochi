"""SQLAlchemy 기반 ``PushTokenRepository`` 구현."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.entities import (
    APNsEnvironment,
    DevicePushToken,
    PushTokenType,
)
from app.modules.notifications.domain.ports import PushTokenRepository as PushTokenRepositoryPort
from app.modules.notifications.infrastructure.orm import DevicePushTokenRow


def _to_entity(row: DevicePushTokenRow) -> DevicePushToken:
    return DevicePushToken(
        owner_id=row.owner_id,
        token=row.token,
        token_type=PushTokenType(row.token_type),
        environment=APNsEnvironment(row.environment),
        mochi_item_id=row.mochi_item_id,
    )


class PostgresPushTokenRepository(PushTokenRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def upsert(self, token: DevicePushToken) -> None:
        stmt = pg_insert(DevicePushTokenRow).values(
            owner_id=token.owner_id,
            token=token.token,
            token_type=token.token_type.value,
            mochi_item_id=token.mochi_item_id,
            environment=token.environment.value,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["token"],
            set_={
                # token 재등록 시 owner 까지 갱신 — apns_device 계정 전환 시 single-owner 보장.
                "owner_id": stmt.excluded.owner_id,
                "token_type": stmt.excluded.token_type,
                "mochi_item_id": stmt.excluded.mochi_item_id,
                "environment": stmt.excluded.environment,
                "updated_at": datetime.utcnow(),
            },
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list_for_owner(self, *, owner_id: UUID, token_type: PushTokenType) -> list[DevicePushToken]:
        stmt = select(DevicePushTokenRow).where(
            DevicePushTokenRow.owner_id == owner_id,
            DevicePushTokenRow.token_type == token_type.value,
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_to_entity(r) for r in rows]
