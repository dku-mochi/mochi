"""ListNotificationsTool 검증 — fake upcoming feed 로 payload·item_id 필터·에러 처리를 고정.

채팅이 "내 알림 뭐 있어?"·"이 기록에 무슨 알림?" 에 답하는 read-only 툴. reschedule/cancel
proposal 의 event_id 가 여기서 나오므로 payload 에 event_id·kind(취소 의미 분기)가 반드시 실린다.
"""

from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest

from app.modules.conversations.infrastructure.tools.list_notifications import (
    ListNotificationsTool,
)
from app.modules.notifications.domain.upcoming_feed import UpcomingNotification

pytestmark = pytest.mark.anyio

_OWNER = uuid4()
_KST = ZoneInfo("Asia/Seoul")


class _FakeSession:
    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *args: Any) -> bool:
        return False


class _FakeFeed:
    """list_upcoming 만 구현 — item_id 를 받으면 그 기록 것만 돌려준다(실 SQL 필터 대역)."""

    def __init__(self, notifications: list[UpcomingNotification]):
        self._notifications = notifications
        self.calls: list[dict[str, Any]] = []

    async def list_upcoming(
        self,
        *,
        owner_id: UUID,
        limit: int,
        item_id: UUID | None = None,
        fire_from: datetime | None = None,
        fire_to: datetime | None = None,
    ) -> list[UpcomingNotification]:
        self.calls.append(
            {
                "owner_id": owner_id,
                "limit": limit,
                "item_id": item_id,
                "fire_from": fire_from,
                "fire_to": fire_to,
            }
        )
        if item_id is not None:
            return [n for n in self._notifications if n.item_id == item_id]
        return self._notifications


def _notif(
    *, item_id: UUID | None = None, kind: str = "deadline", title: str = "마감 알림"
) -> UpcomingNotification:
    return UpcomingNotification(
        event_id=uuid4(),
        kind=kind,
        fire_at=datetime(2026, 7, 10, 9, 0, tzinfo=UTC),
        title=title,
        body="곧 마감이에요",
        original_fire_at=None,
        item_id=item_id,
        intent_id=None,
    )


def _tool(monkeypatch: pytest.MonkeyPatch, feed: _FakeFeed) -> ListNotificationsTool:
    # 툴은 make_upcoming_feed_repository(session) 로 어댑터를 조립한다 — 그 진입점을 fake 로 바꾼다.
    monkeypatch.setattr(
        "app.modules.conversations.infrastructure.tools.list_notifications.make_upcoming_feed_repository",
        lambda session: feed,
    )
    return ListNotificationsTool(session_factory=lambda: _FakeSession())


async def test_lists_upcoming_notifications(monkeypatch: pytest.MonkeyPatch) -> None:
    feed = _FakeFeed([_notif(kind="deadline"), _notif(kind="spaced", title="다시 볼 지식")])
    result = await _tool(monkeypatch, feed).run(owner_id=_OWNER, args={})
    assert result.payload["count"] == 2
    first = result.payload["notifications"][0]
    assert set(first) == {"event_id", "kind", "fire_at", "title", "body", "item_id"}
    assert first["kind"] == "deadline"
    assert feed.calls[0]["item_id"] is None  # 필터 없으면 owner 전체


async def test_empty_when_no_notifications(monkeypatch: pytest.MonkeyPatch) -> None:
    result = await _tool(monkeypatch, _FakeFeed([])).run(owner_id=_OWNER, args={})
    assert result.payload == {"notifications": [], "count": 0}
    assert result.summary == "예정된 알림이 없어요"


async def test_item_id_filters_to_that_record(monkeypatch: pytest.MonkeyPatch) -> None:
    item = uuid4()
    feed = _FakeFeed([_notif(item_id=item), _notif(item_id=uuid4())])
    result = await _tool(monkeypatch, feed).run(owner_id=_OWNER, args={"mochi_item_id": str(item)})
    assert result.payload["count"] == 1
    assert result.payload["notifications"][0]["item_id"] == str(item)
    assert feed.calls[0]["item_id"] == item  # 필터가 포트까지 관통


async def test_invalid_item_id_returns_error(monkeypatch: pytest.MonkeyPatch) -> None:
    feed = _FakeFeed([_notif()])
    result = await _tool(monkeypatch, feed).run(owner_id=_OWNER, args={"mochi_item_id": "not-a-uuid"})
    assert "error" in result.payload
    assert feed.calls == []  # 잘못된 id 면 조회 자체가 안 나간다


async def test_fire_window_passes_through_as_kst(monkeypatch: pytest.MonkeyPatch) -> None:
    # "내일 오는 알림?" — offset 없는 ISO 는 KST 의도로 채워 포트까지 관통한다(경계일 밀림 방지).
    feed = _FakeFeed([_notif()])
    await _tool(monkeypatch, feed).run(
        owner_id=_OWNER, args={"fire_from": "2026-07-10T00:00:00", "fire_to": "2026-07-11T00:00:00"}
    )
    call = feed.calls[0]
    assert call["fire_from"] == datetime(2026, 7, 10, 0, 0, tzinfo=_KST)
    assert call["fire_to"] == datetime(2026, 7, 11, 0, 0, tzinfo=_KST)


async def test_invalid_fire_window_returns_error(monkeypatch: pytest.MonkeyPatch) -> None:
    # 파싱 불가한 값("내일")은 error — 조용히 무시하면 "내일 알림?" 에 전체를 답해 오도한다(codex P3).
    feed = _FakeFeed([_notif()])
    result = await _tool(monkeypatch, feed).run(owner_id=_OWNER, args={"fire_from": "내일"})
    assert "error" in result.payload
    assert feed.calls == []  # 파싱 불가면 조회 자체가 안 나간다
