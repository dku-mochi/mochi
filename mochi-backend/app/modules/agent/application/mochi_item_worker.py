"""MochiItem outbox 워커.

`SELECT ... FOR UPDATE SKIP LOCKED` 패턴으로 outbox 행을 한 건씩 잠그고
``AgentOrchestrator`` 를 (per-run 새 instance, AgentRunPersistence 주입) 실행한 뒤
성공 시 status='done', 영구 실패 시 status='dead_letter', 재시도 가능 실패 시 status='pending' 로 닫는다.

- Postgres `LISTEN mochi_item_outbox` 채널로 즉시 wake-up (TODO)
- 신호 없어도 fallback 폴링 (POLL_INTERVAL_SECONDS)
- 같은 행이 재처리되지 않도록 `locked_until` 사용
- attempts 가 MAX_ATTEMPTS 에 도달하면 DLQ 로 격리
"""

import asyncio
from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_session_factory
from app.core.logging import get_logger
from app.modules.agent.application.orchestrator import AgentOrchestrator, AgentRunPersistence
from app.modules.agent.infrastructure.registry import StaticToolRegistry

log = get_logger("agent.worker")

POLL_INTERVAL_SECONDS = 5
LOCK_DURATION_SECONDS = 60
MAX_ATTEMPTS = 5


class MochiItemWorker:
    def __init__(self, *, max_steps: int):
        self._max_steps = max_steps
        self._stop = asyncio.Event()

    async def run_forever(self) -> None:
        session_factory = get_session_factory()
        while not self._stop.is_set():
            async with session_factory() as session:
                claimed = await self._claim_next(session)
            if claimed is None:
                await asyncio.sleep(POLL_INTERVAL_SECONDS)
                continue
            await self._handle(claimed)

    async def stop(self) -> None:
        self._stop.set()

    async def _claim_next(self, session: AsyncSession) -> "ClaimedOutbox | None":
        now = datetime.utcnow()
        lock_until = now + timedelta(seconds=LOCK_DURATION_SECONDS)
        # `pending` 뿐만 아니라 `in_flight` 상태에서 잠금이 만료된 행도 재청구(reclaim) 한다.
        # 워커 크래시·재시작 시 stuck 방지를 위한 핵심.
        sql = text(
            """
            UPDATE mochi_item_outbox
            SET status='in_flight', locked_until=:lock_until, attempts=attempts+1
            WHERE id = (
                SELECT id FROM mochi_item_outbox
                WHERE (
                       status='pending'
                       OR (status='in_flight' AND locked_until IS NOT NULL AND locked_until < :now)
                      )
                  AND attempts < :max_attempts
                ORDER BY created_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING id, mochi_item_id, owner_id, attempts
            """
        ).bindparams(
            bindparam("lock_until", lock_until),
            bindparam("now", now),
            bindparam("max_attempts", MAX_ATTEMPTS),
        )
        row = (await session.execute(sql)).one_or_none()
        await session.commit()
        if row is None:
            return None
        return ClaimedOutbox(id=row.id, mochi_item_id=row.mochi_item_id, owner_id=row.owner_id, attempts=row.attempts)

    async def _handle(self, claimed: "ClaimedOutbox") -> None:
        session_factory = get_session_factory()
        async with session_factory() as session:
            orchestrator = AgentOrchestrator(
                llm=_NullLLM(),
                tools=StaticToolRegistry(),
                max_steps=self._max_steps,
                persistence=AgentRunPersistence(session),
            )
            try:
                async for _event in orchestrator.run(claimed.mochi_item_id):
                    pass
                await session.execute(
                    text("UPDATE mochi_item_outbox SET status='done' WHERE id=:id").bindparams(id=claimed.id)
                )
                await session.commit()
            except Exception as exc:  # noqa: BLE001
                log.error("worker.failed", mochi_item_id=str(claimed.mochi_item_id), exception=str(exc))
                status_value = "dead_letter" if claimed.attempts >= MAX_ATTEMPTS else "pending"
                await session.execute(
                    text("UPDATE mochi_item_outbox SET status=:s, last_error=:err WHERE id=:id").bindparams(
                        bindparam("s", status_value),
                        bindparam("err", str(exc)[:1024]),
                        bindparam("id", claimed.id),
                    )
                )
                await session.commit()


class ClaimedOutbox:
    __slots__ = ("id", "mochi_item_id", "owner_id", "attempts")

    def __init__(self, *, id: int, mochi_item_id: UUID, owner_id: UUID, attempts: int):
        self.id = id
        self.mochi_item_id = mochi_item_id
        self.owner_id = owner_id
        self.attempts = attempts


class _NullLLM:
    """워커가 deterministic 시퀀스만 흘리도록 하는 placeholder."""

    async def stream(self, **_: object):
        if False:
            yield None  # type: ignore[unreachable]
