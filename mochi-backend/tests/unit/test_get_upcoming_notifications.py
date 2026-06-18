"""GetUpcomingNotifications 단위테스트 — owner/limit 전달 + 빈손 처리.

DB 통합 없이 repository 스텁으로 application 레이어만 본다(test_record_recall_reaction 컨벤션).
실제 pending+fire_at>now+kind 가드 SQL 은 PostgresUpcomingFeedRepository 코드리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

from app.modules.notifications.application.get_upcoming_notifications import (
    GetUpcomingNotifications,
)
from app.modules.notifications.domain.upcoming_feed import UpcomingNotification

_OWNER = uuid4()


class _FeedRepo:
    def __init__(self, items: list[UpcomingNotification]) -> None:
        self._items = items
        self.calls: list[tuple] = []

    async def list_upcoming(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        self.calls.append((owner_id, limit))
        return self._items


def _entry() -> UpcomingNotification:
    return UpcomingNotification(
        event_id=uuid4(),
        kind="deadline",
        fire_at=datetime(2026, 7, 20, 9, 0, tzinfo=UTC),
        title="제출 마감",
        body="과제 제출이 다가와요",
        original_fire_at=None,
        item_id=uuid4(),
        intent_id=uuid4(),
    )


async def test_returns_items_and_passes_owner_limit() -> None:
    items = [_entry(), _entry()]
    repo = _FeedRepo(items)
    out = await GetUpcomingNotifications(feed=repo).execute(owner_id=_OWNER, limit=10)
    assert out == items
    assert repo.calls == [(_OWNER, 10)]


async def test_empty_is_ok() -> None:
    repo = _FeedRepo([])
    out = await GetUpcomingNotifications(feed=repo).execute(owner_id=_OWNER, limit=20)
    assert out == []
