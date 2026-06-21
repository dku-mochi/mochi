from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.ports import MochiItemRepository


@dataclass(slots=True)
class DeleteMochiItemCommand:
    owner_id: UUID
    mochi_item_id: UUID


class DeleteMochiItem:
    """기록 soft delete 유스케이스 — 존재/소유 검증 후 ``deleted_at`` 마킹.

    이미 삭제된 항목은 ``find_by_id`` 가 ``deleted_at IS NULL`` 로 가려 404 가 된다 — 로컬에서
    사라진 화면을 다시 삭제할 수 없으므로 멱등을 따로 보장하지 않는다(재요청 404 가 올바르다).
    """

    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: DeleteMochiItemCommand) -> None:
        item = await self._repo.find_by_id(owner_id=command.owner_id, mochi_item_id=command.mochi_item_id)
        if item is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
        await self._repo.soft_delete(owner_id=command.owner_id, mochi_item_id=command.mochi_item_id)
