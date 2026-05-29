"""MochiItem 조회 use case 모음.

다른 모듈(예: agent)이 MochiItem 조회/소유권 검증이 필요할 때 이 application 진입점만 import한다.
infrastructure (`PostgresMochiItemRepository`) 직접 reach를 차단해 모듈 경계를 유지한다.
"""

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository


def make_mochi_item_repository(session: AsyncSession) -> MochiItemRepository:
    """Factory — 라우터/유스케이스 호출자가 infrastructure를 직접 알 필요 없게 한다."""
    return PostgresMochiItemRepository(session)


@dataclass(slots=True)
class GetMochiItemForOwner:
    repository: MochiItemRepository

    async def execute(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        return await self.repository.find_by_id(owner_id=owner_id, mochi_item_id=mochi_item_id)
