"""list_notifications — 모찌가 앞으로 보낼 예정 알림 조회 채팅 툴 (read-only).

능동 회수 알림(모찌가 자동 설계)은 홈탭 "예정 알림"에서만 보였다 — 채팅에서 "내 알림 뭐
잡혀 있어?"·"이 기록에 무슨 알림 걸려 있지?" 에 답하려면 같은 데이터를 툴로도 노출해야 한다.
reschedule/cancel proposal 의 ``event_id`` 가 여기서 나온다.

로컬 원샷 리마인더(``propose_reminder`` — iOS UNUserNotificationCenter)와 다르다: 이건 서버가
APNs 로 보낼 예약 알림(마감 backoff·주기 넛지·예약 회수)이다. cross-module 진입은
``notifications.application`` 팩토리 경유(ARCHITECTURE §3.3 — conversations 는 notifications
infrastructure 를 직접 import 하지 않는다).
"""

from collections.abc import Callable
from datetime import datetime
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.domain.ports import ChatToolResult
from app.modules.notifications.application.get_upcoming_notifications import (
    GetUpcomingNotifications,
)
from app.modules.notifications.application.repositories import make_upcoming_feed_repository

_KST = ZoneInfo("Asia/Seoul")
#: 채팅 조회 상한 — 홈탭(/recall/upcoming)의 기본과 동일. 개인 사용 규모에서 예정 알림은 이보다 적다.
_LIMIT = 20

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "mochi_item_id": {
            "type": "string",
            "description": (
                "Optional record UUID (from a prior search_items or get_item_detail result). "
                "Set it to list only the notifications tied to that record; omit to list all of "
                "the user's upcoming notifications."
            ),
        },
        "fire_from": {
            "type": "string",
            "description": (
                "Optional ISO datetime (KST assumed if no offset) — only notifications firing "
                "at/after this moment. For '내일/이번주 알림?' resolve the range against the "
                "current KST time in your context (tomorrow → tomorrow 00:00 as fire_from, the "
                "day after 00:00 as fire_to)."
            ),
        },
        "fire_to": {
            "type": "string",
            "description": (
                "Optional ISO datetime, exclusive — only notifications firing before this moment."
            ),
        },
    },
}


class ListNotificationsTool:
    name = "list_notifications"
    label = "예정된 알림을 살펴보고 있어요"
    description = (
        "List the notifications MOCHI will send the user in the future — deadline reminders, "
        "recurring nudges, and scheduled recalls it planned automatically. Use this to answer "
        "'what reminders do I have?', 'anything firing tomorrow?' (fire_from/fire_to), or — with "
        "mochi_item_id — 'what's set for this record?'. Each result carries the event_id needed "
        "to propose rescheduling or cancelling it, and its kind (deadline/nudge/spaced) — "
        "cancelling a spaced recall skips only that occurrence, while a deadline/nudge cancel "
        "stops the whole series, so surface the kind. This is the server's scheduled push queue "
        "— NOT propose_reminder (a new one-shot local reminder on the device). Returns event_id, "
        "kind, fire_at, title, and body per notification, ordered by fire_at."
    )
    parameters = _PARAMETERS

    def __init__(self, session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        item_id: UUID | None = None
        raw_id = args.get("mochi_item_id")
        if raw_id:
            try:
                item_id = UUID(str(raw_id))
            except (ValueError, TypeError):
                return ChatToolResult(
                    payload={"error": "invalid mochi_item_id — use a UUID from search results"},
                    summary="알림을 확인하지 못했어요",
                )
        fire_from = _parse_dt(args.get("fire_from"))
        fire_to = _parse_dt(args.get("fire_to"))
        # 명시된 시각이 파싱 불가면 error — 조용히 무시하면 "내일 알림?" 에 전체를 답해 오도한다(codex P3).
        # (search_items 의 occurs graceful 과 갈라지는 이유: 여기선 시각이 질문의 본질이다.)
        if args.get("fire_from") and fire_from is None:
            return ChatToolResult(
                payload={
                    "error": "fire_from must be ISO datetime — resolve '내일/이번주' against current KST"
                },
                summary="알림을 확인하지 못했어요",
            )
        if args.get("fire_to") and fire_to is None:
            return ChatToolResult(
                payload={"error": "fire_to must be ISO datetime"},
                summary="알림을 확인하지 못했어요",
            )

        async with self._session_factory() as session:
            notifications = await GetUpcomingNotifications(
                feed=make_upcoming_feed_repository(session)
            ).execute(owner_id=owner_id, limit=_LIMIT, item_id=item_id, fire_from=fire_from, fire_to=fire_to)

        items = [
            {
                "event_id": str(n.event_id),
                "kind": n.kind,
                "fire_at": n.fire_at.isoformat(),
                "title": n.title,
                "body": n.body,
                "item_id": str(n.item_id) if n.item_id else None,
            }
            for n in notifications
        ]
        return ChatToolResult(
            payload={"notifications": items, "count": len(items)},
            summary=f"예정 알림 {len(items)}개를 찾았어요" if items else "예정된 알림이 없어요",
            compact={"notifications": [{"event_id": i["event_id"], "title": i["title"]} for i in items[:5]]},
        )


def _parse_dt(raw: Any) -> datetime | None:
    """ISO datetime 파싱 — offset 없으면 KST 의도(프롬프트 {now} 가 KST). search_items 와 동일 정책."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_KST)
    return parsed
