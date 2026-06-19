"""GetSentNotifications 단위테스트 — owner/limit 전달 + 빈손 처리.

DB 통합 없이 repository 스텁으로 application 레이어만 본다(test_get_upcoming_notifications 컨벤션).
실제 status='sent'+sent_at DESC SQL 은 PostgresSentFeedRepository 코드리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import uuid4

from app.modules.notifications.application.get_sent_notifications import (
    GetSentNotifications,
)
from app.modules.notifications.domain.sent_feed import SentNotification

_OWNER = uuid4()


class _SentRepo:
    def __init__(self, items: list[SentNotification]) -> None:
        self._items = items
        self.calls: list[tuple] = []

    async def list_sent(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        self.calls.append((owner_id, limit))
        return self._items


def _entry() -> SentNotification:
    return SentNotification(
        event_id=uuid4(),
        kind="deadline",
        sent_at=datetime(2026, 6, 18, 9, 0, tzinfo=UTC),
        opened_at=None,
        dismissed_at=None,
        title="제출 마감",
        body="과제 제출이 다가와요",
        item_id=uuid4(),
        intent_id=uuid4(),
    )


async def test_returns_items_and_passes_owner_limit() -> None:
    items = [_entry(), _entry()]
    repo = _SentRepo(items)
    out = await GetSentNotifications(feed=repo).execute(owner_id=_OWNER, limit=10)
    assert out == items
    assert repo.calls == [(_OWNER, 10)]


async def test_empty_is_ok() -> None:
    repo = _SentRepo([])
    out = await GetSentNotifications(feed=repo).execute(owner_id=_OWNER, limit=20)
    assert out == []
