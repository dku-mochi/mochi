"""intent instance lifecycle 전이 use case 단위 테스트 — 캘린더 todo 완료/완료취소.

DB 통합 fixture 없이 repository 스텁으로 application 레이어의 정책 검증·전이 매핑만 본다.
owner/instance 3중 scoped SQL 은 PostgresMochiItemRepository 코드 리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import ConflictError, NotFoundError
from app.modules.mochi_items.application.update_instance_lifecycle import (
    UpdateInstanceLifecycle,
    UpdateInstanceLifecycleCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
)
from app.shared.intent import Intent

_OWNER = uuid4()


def _item(instance: IntentInstance) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(
            channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)
        ),
        intent_instances=(instance,),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _Repo:
    """find_by_id + update_instance_lifecycle 만 구현하는 스텁 (in-place 갱신)."""

    def __init__(self, item: MochiItem | None) -> None:
        self._item = item

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        if self._item is None or self._item.id != mochi_item_id:
            return None
        return self._item

    async def update_instance_lifecycle(  # type: ignore[no-untyped-def]
        self, *, owner_id, mochi_item_id, instance_id, lifecycle
    ):
        if self._item is None:
            return False
        for inst in self._item.intent_instances:
            if inst.id == instance_id:
                inst.lifecycle = lifecycle
                return True
        return False


def _command(
    item: MochiItem, instance_id, target: InstanceLifecycleState
) -> UpdateInstanceLifecycleCommand:
    return UpdateInstanceLifecycleCommand(
        owner_id=_OWNER, mochi_item_id=item.id, instance_id=instance_id, target=target
    )


async def test_complete_active_todo_archives_with_reason() -> None:
    inst = IntentInstance(intent_type=Intent.TODO)
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(item))  # type: ignore[arg-type]
    result = await use_case.execute(
        _command(
            item,
            inst.id,
            InstanceLifecycleState(
                kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
            ),
        )
    )
    assert result.intent_instances[0].lifecycle.kind is InstanceLifecycleKind.ARCHIVED
    assert result.intent_instances[0].lifecycle.archive_reason is ArchiveReason.TODO_COMPLETED


async def test_uncomplete_archived_todo_back_to_active() -> None:
    # 완료 취소 — 잘못 누른 완료를 미완료로 되돌린다(역전이).
    inst = IntentInstance(
        intent_type=Intent.TODO,
        lifecycle=InstanceLifecycleState(
            kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
        ),
    )
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(item))  # type: ignore[arg-type]
    result = await use_case.execute(
        _command(item, inst.id, InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE))
    )
    assert result.intent_instances[0].lifecycle.kind is InstanceLifecycleKind.ACTIVE
    assert result.intent_instances[0].lifecycle.archive_reason is None


async def test_illegal_transition_raises_conflict() -> None:
    # schedule 은 완료(archive)를 되돌릴 수 없다 — archived→active 불법(todo 한정 역전이).
    inst = IntentInstance(
        intent_type=Intent.SCHEDULE,
        lifecycle=InstanceLifecycleState(
            kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.SCHEDULE_ENDED
        ),
    )
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(item))  # type: ignore[arg-type]
    with pytest.raises(ConflictError):
        await use_case.execute(
            _command(item, inst.id, InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE))
        )


async def test_missing_item_raises_not_found() -> None:
    inst = IntentInstance(intent_type=Intent.TODO)
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(None))  # type: ignore[arg-type]
    with pytest.raises(NotFoundError):
        await use_case.execute(
            _command(item, inst.id, InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE))
        )


async def test_missing_instance_raises_not_found() -> None:
    inst = IntentInstance(intent_type=Intent.TODO)
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(item))  # type: ignore[arg-type]
    with pytest.raises(NotFoundError):
        await use_case.execute(
            _command(
                item,
                uuid4(),
                InstanceLifecycleState(
                    kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
                ),
            )
        )


async def test_same_state_is_idempotent_noop() -> None:
    """이미 완료(archived)인 todo 에 같은 완료를 재전송하면 409 가 아니라 no-op(멱등).

    응답 유실 재시도·빠른 더블탭이 409 로 거절되어 iOS 낙관적 업데이트가 오롤백되는 것을 막는다.
    """
    target = InstanceLifecycleState(
        kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
    )
    inst = IntentInstance(intent_type=Intent.TODO, lifecycle=target)
    item = _item(inst)
    use_case = UpdateInstanceLifecycle(repository=_Repo(item))  # type: ignore[arg-type]
    result = await use_case.execute(_command(item, inst.id, target))
    assert result.intent_instances[0].lifecycle == target
