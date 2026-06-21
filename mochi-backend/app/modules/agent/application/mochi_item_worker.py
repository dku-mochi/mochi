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
from app.core.deps import get_agent_llm, get_apns_client, get_profile_summarizer, get_voyage_client
from app.core.logging import get_logger
from app.modules.agent.application.orchestrator import AgentOrchestrator, AgentRunPersistence
from app.modules.agent.application.refresh_user_profile import RefreshUserProfile
from app.modules.agent.infrastructure.mochi_item_gateway import MochiItemGatewayAdapter
from app.modules.agent.infrastructure.profile_store import PostgresUserProfileStore
from app.modules.agent.infrastructure.registry import StaticToolRegistry
from app.modules.mochi_items.application.queries import GetMochiItemForOwner, make_mochi_item_repository
from app.modules.notifications.application.recall_planning_factory import (
    make_generate_recall_candidates,
    make_plan_recall_notifications,
)
from app.modules.notifications.application.repositories import make_push_token_repository
from app.modules.notifications.application.send_notification import (
    AnalysisNotification,
    SendAnalysisNotification,
)

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
                  -- 같은 mochi_item 이 이미 처리 중(lock 유효)이면 그 item 의 다른 행은 잡지 않는다 —
                  -- 재분석 중복 emit 시 worker 병렬 실행 → apply_analysis delete-reinsert race 방지(item-level 직렬).
                  AND mochi_item_id NOT IN (
                      SELECT mochi_item_id FROM mochi_item_outbox
                      WHERE status='in_flight' AND locked_until IS NOT NULL AND locked_until >= :now
                  )
                ORDER BY created_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING id, mochi_item_id, owner_id, attempts, reanalysis_hint
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
        log.info(
            "worker.claimed",
            outbox_id=row.id,
            mochi_item_id=str(row.mochi_item_id),
            owner_id=str(row.owner_id),
            attempts=row.attempts,
            locked_until=lock_until.isoformat(),
        )
        return ClaimedOutbox(
            id=row.id,
            mochi_item_id=row.mochi_item_id,
            owner_id=row.owner_id,
            attempts=row.attempts,
            reanalysis_hint=row.reanalysis_hint,
        )

    async def _handle(self, claimed: "ClaimedOutbox") -> None:
        log.info(
            "worker.handle_started",
            outbox_id=claimed.id,
            mochi_item_id=str(claimed.mochi_item_id),
            owner_id=str(claimed.owner_id),
            attempts=claimed.attempts,
        )
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
                # voyage 키 미설정 시 None — INDEXED 색인만 건너뛰고 분석은 정상 진행.
                embedder=get_voyage_client(),
            )
            try:
                # 전체 실행 상한 — lock(LOCK_DURATION_SECONDS)보다 짧게 강제해 mid-run reclaim 방지.
                await asyncio.wait_for(
                    _drain(orchestrator, claimed.mochi_item_id, claimed.owner_id, claimed.reanalysis_hint),
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
                    # 성공 종료 시 재분석 힌트를 비운다 — 분석에 쓰인 후 행과 함께 소멸(transient invariant).
                    text(
                        "UPDATE mochi_item_outbox SET status='done', reanalysis_hint=NULL WHERE id=:id"
                    ).bindparams(id=claimed.id)
                )
                await session.commit()
                log.info(
                    "worker.done",
                    outbox_id=claimed.id,
                    mochi_item_id=str(claimed.mochi_item_id),
                    owner_id=str(claimed.owner_id),
                    attempts=claimed.attempts,
                )
            except Exception as exc:  # noqa: BLE001
                is_dead = claimed.attempts >= MAX_ATTEMPTS
                status_value = "dead_letter" if is_dead else "pending"
                log.error(
                    "worker.failed",
                    outbox_id=claimed.id,
                    mochi_item_id=str(claimed.mochi_item_id),
                    owner_id=str(claimed.owner_id),
                    attempts=claimed.attempts,
                    next_status=status_value,
                    exception=str(exc),
                    exc_info=True,
                )
                await session.execute(
                    text("UPDATE mochi_item_outbox SET status=:s, last_error=:err WHERE id=:id").bindparams(
                        bindparam("s", status_value),
                        bindparam("err", str(exc)[:1024]),
                        bindparam("id", claimed.id),
                    )
                )
                if is_dead:
                    # 영구 실패 → item 처리상태를 failed 로 확립 (iOS 폴링 컷오버 신호, §7.1).
                    # 재시도 가능 실패는 ingested 유지 — 다음 attempt 가 analyzed 로 닫는다.
                    await session.execute(
                        text("UPDATE mochi_items SET lifecycle_kind='failed' WHERE id=:id").bindparams(
                            bindparam("id", claimed.mochi_item_id),
                        )
                    )
                await session.commit()
                return  # 분석 실패 — push 없음 (정상 done 경로만 아래 push 로 진행).

        # done 으로 닫힌 경우만 도달 — 분석완료 push (best-effort, 독립 세션, 분석 try 밖).
        # push 실패가 분석을 롤백/되돌리지 않는다(이미 done 커밋). 누락은 iOS reconcile 이 메운다. 재시도 없음.
        await self._notify_analysis_complete(claimed.owner_id, claimed.mochi_item_id)

        # 능동 회수 알림 plan 설계 (P2) — push 와 분리된 별도 best-effort 단계. 독립 세션, 재시도 없음.
        # 분석을 롤백/되돌리지 않고, 실패해도 worker 루프를 죽이지 않는다(push 와 동일 격리 계약).
        await self._plan_recall_notifications(claimed.owner_id, claimed.mochi_item_id)

        # 능동 회수 트랙 C 후보 생성 (P7~P9) — 새 item 의 임베딩 ANN 으로 유사 과거 기록을 찾아
        # kind=recall 로 outbox 직행. P2 와 동일한 best-effort 격리(독립 세션, 실패해도 분석 done 유지).
        await self._generate_recall_candidates(claimed.owner_id, claimed.mochi_item_id)

    async def _notify_analysis_complete(self, owner_id: UUID, mochi_item_id: UUID) -> None:
        # get_apns_client() 도 try 안 — p8 misconfig(base64/PEM/non-EC) 예외가 worker 루프를
        # 죽이지 않게(격리 계약). best-effort, 재시도 없음.
        log.info(
            "push.notify_started",
            owner_id=str(owner_id),
            mochi_item_id=str(mochi_item_id),
        )
        try:
            apns = get_apns_client()
            if apns is None:
                log.info(
                    "push.notify_skipped",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    reason="apns_not_configured",
                )
                return  # APNs 미설정(local dev) — push no-op.
            async with get_session_factory()() as push_session:
                item = await GetMochiItemForOwner(
                    repository=make_mochi_item_repository(push_session)
                ).execute(owner_id=owner_id, mochi_item_id=mochi_item_id)
                if item is None:
                    log.warning(
                        "push.notify_skipped",
                        owner_id=str(owner_id),
                        mochi_item_id=str(mochi_item_id),
                        reason="item_not_found",
                    )
                    return
                await SendAnalysisNotification(
                    tokens=make_push_token_repository(push_session),
                    apns=apns,
                ).run(
                    owner_id=owner_id,
                    mochi_item_id=mochi_item_id,
                    notification=AnalysisNotification(
                        needs_review=item.needs_review,
                        summary=item.summary,
                        review_options=item.review_options,
                    ),
                )
                log.info(
                    "push.notify_finished",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    needs_review=item.needs_review,
                )
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "push.send_failed",
                mochi_item_id=str(mochi_item_id),
                exception=str(exc),
                exc_info=True,
            )

    async def _plan_recall_notifications(self, owner_id: UUID, mochi_item_id: UUID) -> None:
        # 능동 회수 알림 설계(P2). 분석 결과의 intent_instances 로 결정적 eligibility 게이트 →
        # eligible 건만 LLM 플래너가 시점·시각·문구 설계 → notification_plan 영속.
        # best-effort, 재시도 없음 — 실패해도 분석은 이미 done 커밋이고 worker 루프를 죽이지 않는다.
        try:
            async with get_session_factory()() as plan_session:
                item = await GetMochiItemForOwner(
                    repository=make_mochi_item_repository(plan_session)
                ).execute(owner_id=owner_id, mochi_item_id=mochi_item_id)
                if item is None:
                    return
                use_case = make_plan_recall_notifications(plan_session, owner_id=owner_id)
                created = await use_case.run(
                    owner_id=owner_id,
                    mochi_item_id=mochi_item_id,
                    intent_instances=item.intent_instances,
                )
                await plan_session.commit()
                log.info(
                    "recall.plan_run_finished",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    created=created,
                )
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "recall.plan_run_failed",
                owner_id=str(owner_id),
                mochi_item_id=str(mochi_item_id),
                exception=str(exc),
                exc_info=True,
            )

    async def _generate_recall_candidates(self, owner_id: UUID, mochi_item_id: UUID) -> None:
        # 능동 회수 트랙 C(P7~P9). 새 item 임베딩 ANN → 게이트 → kind=recall outbox 직행.
        # best-effort, 재시도 없음 — 실패해도 분석은 이미 done 커밋이고 worker 루프를 죽이지 않는다.
        try:
            async with get_session_factory()() as recall_session:
                created = await make_generate_recall_candidates(recall_session).run(
                    owner_id=owner_id, mochi_item_id=mochi_item_id
                )
                await recall_session.commit()
                log.info(
                    "recall.candidate_run_finished",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    created=created,
                )
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "recall.candidate_run_failed",
                owner_id=str(owner_id),
                mochi_item_id=str(mochi_item_id),
                exception=str(exc),
                exc_info=True,
            )


class ClaimedOutbox:
    __slots__ = ("id", "mochi_item_id", "owner_id", "attempts", "reanalysis_hint")

    def __init__(
        self,
        *,
        id: int,
        mochi_item_id: UUID,
        owner_id: UUID,
        attempts: int,
        reanalysis_hint: str | None = None,
    ):
        self.id = id
        self.mochi_item_id = mochi_item_id
        self.owner_id = owner_id
        self.attempts = attempts
        self.reanalysis_hint = reanalysis_hint


async def _drain(
    orchestrator: AgentOrchestrator,
    mochi_item_id: UUID,
    owner_id: UUID,
    reanalysis_hint: str | None = None,
) -> None:
    """orchestrator.run 의 StreamEvent 를 소비한다 (워커는 SSE 를 흘리지 않음)."""
    async for _event in orchestrator.run(mochi_item_id, owner_id, reanalysis_hint=reanalysis_hint):
        pass
