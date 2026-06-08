from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import ConflictError, NotFoundError
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleState


@dataclass(slots=True)
class UpdateInstanceLifecycleCommand:
    owner_id: UUID
    mochi_item_id: UUID
    instance_id: UUID
    target: InstanceLifecycleState


class UpdateInstanceLifecycle:
    """intent instance 의 의미 lifecycle 전이 유스케이스 — 캘린더 todo 완료/완료취소.

    전이 합법성은 instance 의 ``intent_type`` 으로 ``lifecycle_policy`` 가 검증한다(불법이면 409).
    todo 는 ``active ↔ archived(todoCompleted)`` 양방향이 합법 — 잘못 누른 완료를 되돌릴 수 있다.
    """

    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: UpdateInstanceLifecycleCommand) -> MochiItem:
        item = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        if item is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
        instance = next(
            (i for i in item.intent_instances if i.id == command.instance_id), None
        )
        if instance is None:
            raise NotFoundError("Intent instance not found", code="intent_instance.not_found")
        # 멱등 — 이미 목표 상태면 no-op(200). 완료 토글은 set-state 의미라, 같은 상태 재전송(응답 유실
        # 재시도·빠른 더블탭)이 409 로 거절되어 iOS 낙관적 업데이트가 오롤백되는 것을 막는다.
        if instance.lifecycle == command.target:
            return item
        if not is_allowed(instance.intent_type, instance.lifecycle, command.target):
            raise ConflictError(
                f"Illegal lifecycle transition for {instance.intent_type.value}: "
                f"{instance.lifecycle.kind.value} → {command.target.kind.value}",
                code="intent_instance.illegal_transition",
            )
        updated = await self._repo.update_instance_lifecycle(
            owner_id=command.owner_id,
            mochi_item_id=command.mochi_item_id,
            instance_id=command.instance_id,
            lifecycle=command.target,
        )
        if not updated:
            raise NotFoundError("Intent instance not found", code="intent_instance.not_found")
        refreshed = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        assert refreshed is not None  # 방금 UPDATE 성공 → 반드시 존재
        return refreshed
