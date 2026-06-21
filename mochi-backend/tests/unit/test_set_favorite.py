"""즐겨찾기 set-state use case 단위 테스트.

DB 통합 fixture 없이 repository 스텁으로 application 레이어의 멱등·404·set 매핑만 본다.
owner-scoped SQL 은 PostgresMochiItemRepository 코드 리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.application.set_favorite import (
    SetFavorite,
    SetFavoriteCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)

_OWNER = uuid4()


def _item(is_favorite: bool = False) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
        is_favorite=is_favorite,
    )


class _Repo:
    """find_by_id + set_favorite 만 구현하는 스텁 (in-place 갱신, rowcount 카운트)."""

    def __init__(self, item: MochiItem | None) -> None:
        self._item = item
        self.set_calls = 0

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        if self._item is None or self._item.id != mochi_item_id:
            return None
        return self._item

    async def set_favorite(self, *, owner_id, mochi_item_id, is_favorite):  # type: ignore[no-untyped-def]
        self.set_calls += 1
        if self._item is None or self._item.id != mochi_item_id:
            return False
        self._item.is_favorite = is_favorite
        return True


async def test_set_favorite_true() -> None:
    item = _item(is_favorite=False)
    repo = _Repo(item)
    use_case = SetFavorite(repository=repo)  # type: ignore[arg-type]
    result = await use_case.execute(
        SetFavoriteCommand(owner_id=_OWNER, mochi_item_id=item.id, is_favorite=True)
    )
    assert result.is_favorite is True


async def test_unset_favorite_false() -> None:
    item = _item(is_favorite=True)
    repo = _Repo(item)
    use_case = SetFavorite(repository=repo)  # type: ignore[arg-type]
    result = await use_case.execute(
        SetFavoriteCommand(owner_id=_OWNER, mochi_item_id=item.id, is_favorite=False)
    )
    assert result.is_favorite is False


async def test_same_state_is_idempotent_noop() -> None:
    # 이미 즐겨찾기인 항목에 isFavorite=true 재전송 → set_favorite 호출 없이 no-op(빠른 더블탭 방어).
    item = _item(is_favorite=True)
    repo = _Repo(item)
    use_case = SetFavorite(repository=repo)  # type: ignore[arg-type]
    result = await use_case.execute(
        SetFavoriteCommand(owner_id=_OWNER, mochi_item_id=item.id, is_favorite=True)
    )
    assert result.is_favorite is True
    assert repo.set_calls == 0


async def test_missing_item_raises_not_found() -> None:
    use_case = SetFavorite(repository=_Repo(None))  # type: ignore[arg-type]
    with pytest.raises(NotFoundError):
        await use_case.execute(SetFavoriteCommand(owner_id=_OWNER, mochi_item_id=uuid4(), is_favorite=True))
