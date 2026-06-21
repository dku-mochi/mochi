"""상세 열람 로깅 use case 단위 테스트.

repository 스텁으로 application 레이어의 best-effort no-op 과 source 전달만 본다.
owner-scoped INSERT 는 PostgresMochiItemRepository 코드 리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

from app.modules.mochi_items.application.log_item_access import (
    LogItemAccess,
    LogItemAccessCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import AccessSource

_OWNER = uuid4()


def _item() -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _Repo:
    """find_by_id + log_access 만 구현하는 스텁 (호출 인자 기록)."""

    def __init__(self, item: MochiItem | None) -> None:
        self._item = item
        self.logged: list[tuple] = []

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        if self._item is None or self._item.id != mochi_item_id:
            return None
        return self._item

    async def log_access(self, *, owner_id, mochi_item_id, source):  # type: ignore[no-untyped-def]
        self.logged.append((owner_id, mochi_item_id, source))


async def test_logs_access_with_source() -> None:
    item = _item()
    repo = _Repo(item)
    use_case = LogItemAccess(repository=repo)  # type: ignore[arg-type]
    await use_case.execute(
        LogItemAccessCommand(owner_id=_OWNER, mochi_item_id=item.id, source=AccessSource.CHAT)
    )
    assert repo.logged == [(_OWNER, item.id, AccessSource.CHAT)]


async def test_missing_item_is_noop_no_raise() -> None:
    # best-effort: 없는/타 owner item 은 조용히 무시 — 예외도, log_access 호출도 없다.
    repo = _Repo(None)
    use_case = LogItemAccess(repository=repo)  # type: ignore[arg-type]
    await use_case.execute(
        LogItemAccessCommand(owner_id=_OWNER, mochi_item_id=uuid4(), source=AccessSource.SEARCH)
    )
    assert repo.logged == []
