"""notification_outbox 반응 갱신 + stop plan cancel — `RecallReactionRepositoryPort` 구현 (P5).

P3+P4 worker(notification_worker/recall_occurrence)와 별개 파일 — worker 비접촉.

멱등·보안(codex-6): 모든 반응 갱신은 `(event_id, owner_id)` + `status='sent'` atomic UPDATE
가드로 친다. opened/dismissed 는 `... IS NULL` 조건까지 더해 first-write-wins(중복 탭·남의
event_id 조작 방어). rowcount 로 호출부가 "이번이 첫 기록인가"를 판정한다.
"""

from contextlib import AbstractAsyncContextManager
from datetime import datetime
from typing import Any, cast
from uuid import UUID

from sqlalchemy import CursorResult, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.recall_reaction import (
    RecallReactionRepositoryPort,
    SentRecallEvent,
)
from app.modules.notifications.infrastructure.orm import (
    NotificationOutboxRow,
    NotificationPlanRow,
)

_CANCEL_REASON_USER_DISMISS = "user_dismiss"


class PostgresRecallReactionRepository(RecallReactionRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_sent_event(
        self, *, event_id: UUID, owner_id: UUID
    ) -> SentRecallEvent | None:
        stmt = select(
            NotificationOutboxRow.event_id,
            NotificationOutboxRow.kind,
            NotificationOutboxRow.plan_id,
            NotificationOutboxRow.source_item_id,
            NotificationOutboxRow.source_intent_id,
        ).where(
            NotificationOutboxRow.event_id == event_id,
            NotificationOutboxRow.owner_id == owner_id,
            NotificationOutboxRow.status == "sent",
        )
        row = (await self._session.execute(stmt)).first()
        if row is None:
            return None
        return SentRecallEvent(
            event_id=row.event_id,
            kind=row.kind,
            plan_id=row.plan_id,
            source_item_id=row.source_item_id,
            source_intent_id=row.source_intent_id,
        )

    async def mark_opened(self, *, event_id: UUID, owner_id: UUID) -> int:
        # first-write-wins atomic UPDATE — opened_at IS NULL 인 sent 행만. rowcount=0 이면
        # 이미 opened(멱등 no-op) 또는 행 없음(호출부가 find_sent_event 로 분기).
        stmt = (
            update(NotificationOutboxRow)
            .where(
                NotificationOutboxRow.event_id == event_id,
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "sent",
                NotificationOutboxRow.opened_at.is_(None),
            )
            .values(opened_at=datetime.utcnow())
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        await self._session.flush()
        return result.rowcount or 0

    async def mark_dismissed(self, *, event_id: UUID, owner_id: UUID) -> int:
        stmt = (
            update(NotificationOutboxRow)
            .where(
                NotificationOutboxRow.event_id == event_id,
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "sent",
                NotificationOutboxRow.dismissed_at.is_(None),
            )
            .values(dismissed_at=datetime.utcnow())
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        await self._session.flush()
        return result.rowcount or 0

    async def cancel_plan(self, *, plan_id: UUID, owner_id: UUID) -> None:
        # "이 기억 그만" 영구(codex-7) — owner-scope + status='active' 가드(cross-tenant·재취소 차단).
        stmt = (
            update(NotificationPlanRow)
            .where(
                NotificationPlanRow.id == plan_id,
                NotificationPlanRow.owner_id == owner_id,
                NotificationPlanRow.status == "active",
            )
            .values(
                status="cancelled",
                cancel_reason=_CANCEL_REASON_USER_DISMISS,
                cancelled_at=datetime.utcnow(),
            )
        )
        await self._session.execute(stmt)
        # 잔여 outbox 대칭 정리(P2): intent_archived 경로(worker)는 plan cancel 시 pending/deferred
        # outbox 를 skipped(cancelled) 로 치우는데 stop(user_dismiss) 경로는 안 치워 비대칭이었다.
        # 같은 plan 의 미발송 outbox 를 skipped(cancelled) 로 마킹(owner-scope).
        await self._session.execute(
            update(NotificationOutboxRow)
            .where(
                NotificationOutboxRow.plan_id == plan_id,
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status.in_(("pending", "deferred")),
            )
            .values(status="skipped", skip_reason="cancelled")
        )
        await self._session.flush()

    def savepoint(self) -> AbstractAsyncContextManager[None]:
        # begin_nested = SAVEPOINT — 안에서 DB 에러가 나면 이 savepoint 만 롤백되어 outer 트랜잭션
        # (이미 flush 된 opened_at)이 aborted 되지 않는다(P1#4). recall_plan_repository 컨벤션과 동일.
        return cast(AbstractAsyncContextManager[None], self._session.begin_nested())
