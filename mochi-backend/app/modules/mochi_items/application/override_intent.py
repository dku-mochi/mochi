"""사용자가 알림에서 다른 의도를 골랐을 때 MochiItem 의 primary intent 를 교체한다.

흐름:
1. ``find_by_id`` 로 owner-scoped 조회 (cross-tenant 차단).
2. ``MochiItem.swap_primary`` — 이전 primary 가 secondary 의 맨 앞으로 이동.
3. ``update_primary_intent`` 로 row 반영. applicability 분포는 유지 (LLM 원 분포 보존).

PATCH 의 본질이 idempotent 라 idempotency key 는 필요하지 않다.
"""

from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.shared.intent import Intent


@dataclass(slots=True)
class OverrideIntentCommand:
    owner_id: UUID
    mochi_item_id: UUID
    new_primary: Intent


class OverrideIntent:
    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: OverrideIntentCommand) -> MochiItem:
        item = await self._repo.find_by_id(
            owner_id=command.owner_id,
            mochi_item_id=command.mochi_item_id,
        )
        if item is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")

        item.swap_primary(command.new_primary)
        await self._repo.update_primary_intent(
            owner_id=command.owner_id,
            mochi_item_id=item.id,
            new_primary=item.intent,
            new_secondary=item.secondary_intents,
        )
        return item
