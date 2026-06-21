"""pending outbox reschedule/veto — `UpcomingOverrideRepositoryPort` 구현. owner-scope atomic.

reaction repo(status='sent' 전제)와 별개 — 여기는 status='pending' + fire_at>now() 가드.
worker 비접촉(fire_at 직접 갱신은 materialize 와 충돌 없음 — occurrence identity 는 seq).
"""

from datetime import datetime
from typing import Any, cast
from uuid import UUID

from sqlalchemy import CursorResult, func, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.upcoming_override import (
    UpcomingOverrideRepositoryPort,
)
from app.modules.notifications.infrastructure.orm import NotificationOutboxRow

_SKIP_REASON_USER_VETO = "user_veto"


class PostgresUpcomingOverrideRepository(UpcomingOverrideRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def reschedule(self, *, event_id: UUID, owner_id: UUID, new_fire_at: datetime) -> int:
        # 첫 조정 때만 original 보존(COALESCE) — 여러 번 옮겨도 최초 모찌 원안 유지.
        # WHERE fire_at>now() — 이미 발송 시점 지난 행은 옮기지 못함(중복/즉시발송 방지).
        stmt = (
            update(NotificationOutboxRow)
            .where(
                NotificationOutboxRow.event_id == event_id,
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "pending",
                NotificationOutboxRow.fire_at > func.now(),
            )
            .values(
                original_fire_at=func.coalesce(
                    NotificationOutboxRow.original_fire_at,
                    NotificationOutboxRow.fire_at,
                ),
                fire_at=new_fire_at,
            )
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        await self._session.flush()
        return result.rowcount or 0

    async def veto_pending(
        self, *, event_id: UUID, owner_id: UUID
    ) -> tuple[int, UUID | None, str | None]:
        # 대상 pending 1건을 skipped(user_veto). RETURNING 으로 plan_id+kind 회수 → 호출부가 kind 로
        # 분기(spaced=다음 회차 전진 / deadline·nudge=cancel_plan 시리즈 중단).
        stmt = (
            update(NotificationOutboxRow)
            .where(
                NotificationOutboxRow.event_id == event_id,
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "pending",
                NotificationOutboxRow.fire_at > func.now(),
            )
            .values(status="skipped", skip_reason=_SKIP_REASON_USER_VETO)
            .returning(NotificationOutboxRow.plan_id, NotificationOutboxRow.kind)
        )
        rows = (await self._session.execute(stmt)).all()
        await self._session.flush()
        if not rows:
            return 0, None, None
        return len(rows), rows[0].plan_id, rows[0].kind
