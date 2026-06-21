"""기록 soft delete use case 단위 테스트.

DB 통합 fixture 없이 repository 스텁으로 application 레이어의 존재/소유 검증만 본다.
owner-scoped UPDATE(deleted_at) SQL 은 PostgresMochiItemRepository 코드 리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.application.delete_mochi_item import (
    DeleteMochiItem,
    DeleteMochiItemCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)

_OWNER = uuid4()


def _item() -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)),
        intent_instances=(),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _Repo:
    """find_by_id + soft_delete 만 구현하는 스텁. owner+id 일치할 때만 보이고, soft_delete 호출을 기록."""

    def __init__(self, item: MochiItem | None, owner=None) -> None:  # type: ignore[no-untyped-def]
        self._item = item
        self._owner = owner
        self.deleted: tuple | None = None

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        if self._item is None or self._item.id != mochi_item_id or owner_id != self._owner:
            return None
        return self._item

    async def soft_delete(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        self.deleted = (owner_id, mochi_item_id)


async def test_delete_existing_marks_soft_delete() -> None:
    item = _item()
    repo = _Repo(item, owner=_OWNER)
    use_case = DeleteMochiItem(repository=repo)  # type: ignore[arg-type]
    await use_case.execute(DeleteMochiItemCommand(owner_id=_OWNER, mochi_item_id=item.id))
    assert repo.deleted == (_OWNER, item.id)


async def test_delete_missing_raises_not_found() -> None:
    repo = _Repo(None)
    use_case = DeleteMochiItem(repository=repo)  # type: ignore[arg-type]
    with pytest.raises(NotFoundError):
        await use_case.execute(DeleteMochiItemCommand(owner_id=_OWNER, mochi_item_id=uuid4()))
    assert repo.deleted is None  # 없는 항목엔 soft_delete 를 호출하지 않는다


async def test_delete_other_owner_item_raises_not_found() -> None:
    # 다른 owner 가 남의 항목 id 로 삭제 시도 — find_by_id 가 owner-scoped 라 None → 404, soft_delete 미호출.
    item = _item()
    repo = _Repo(item, owner=_OWNER)
    use_case = DeleteMochiItem(repository=repo)  # type: ignore[arg-type]
    with pytest.raises(NotFoundError):
        await use_case.execute(DeleteMochiItemCommand(owner_id=uuid4(), mochi_item_id=item.id))
    assert repo.deleted is None
