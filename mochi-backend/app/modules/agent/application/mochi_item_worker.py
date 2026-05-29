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

from app.core.config import get_settings
from app.core.db import get_session_factory
from app.core.deps import get_agent_llm, get_profile_summarizer
from app.core.logging import get_logger
from app.modules.agent.application.orchestrator import AgentOrchestrator, AgentRunPersistence
from app.modules.agent.application.refresh_user_profile import RefreshUserProfile
from app.modules.agent.infrastructure.mochi_item_gateway import MochiItemGatewayAdapter
from app.modules.agent.infrastructure.profile_store import PostgresUserProfileStore
from app.modules.agent.infrastructure.registry import StaticToolRegistry

log = get_logger("agent.worker")

POLL_INTERVAL_SECONDS = 5
# lock 은 한 건의 최대 처리시간(agent_total_timeout + 프로필 refresh)보다 길어야 한다.
# 그렇지 않으면 처리 중에 lock 이 만료돼 다른 워커가 같은 행을 reclaim → 이중 실행.
LOCK_DURATION_SECONDS = 180
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
        settings = get_settings()
        async with session_factory() as session:
            gateway = MochiItemGatewayAdapter(session)
            profile_store = PostgresUserProfileStore(session)
            orchestrator = AgentOrchestrator(
                llm=get_agent_llm(),
                tools=StaticToolRegistry(),
                max_steps=self._max_steps,
                persistence=AgentRunPersistence(session),
                gateway=gateway,
                profile_store=profile_store,
            )
            try:
                # 전체 실행 상한 — lock(LOCK_DURATION_SECONDS)보다 짧게 강제해 mid-run reclaim 방지.
                await asyncio.wait_for(
                    _drain(orchestrator, claimed.mochi_item_id, claimed.owner_id),
                    timeout=settings.agent_total_timeout_seconds,
                )
                # 개인화 프로필 디바운스 갱신 — best-effort (실패해도 분석은 이미 완료·커밋됨).
                try:
                    await RefreshUserProfile(
                        gateway=gateway,
                        store=profile_store,
                        summarizer=get_profile_summarizer(),
                        window_size=settings.profile_window_size,
                        refresh_every_n=settings.profile_refresh_every_n_items,
                        model_version=settings.gemini_agent_model,
                    ).run(owner_id=claimed.owner_id)
                except Exception as exc:  # noqa: BLE001
                    # 프로필 flush 실패가 세션을 오염시키면 이후 outbox UPDATE 가 PendingRollbackError
                    # 로 연쇄 실패한다 → rollback 으로 세션을 복구한 뒤 진행 (분석은 이미 커밋됨).
                    await session.rollback()
                    log.warning(
                        "profile.refresh_failed",
                        owner_id=str(claimed.owner_id),
                        exception=str(exc),
                    )
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


async def _drain(orchestrator: AgentOrchestrator, mochi_item_id: UUID, owner_id: UUID) -> None:
    """orchestrator.run 의 StreamEvent 를 소비한다 (워커는 SSE 를 흘리지 않음)."""
    async for _event in orchestrator.run(mochi_item_id, owner_id):
        pass
