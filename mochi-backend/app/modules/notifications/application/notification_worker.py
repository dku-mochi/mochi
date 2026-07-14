"""능동 회수 알림 cron 워커 (P3 materialize+가드+종료연동 / P4 발송+APNs분류+dry-run).

`MochiItemWorker` 패턴(run_forever 폴링, FOR UPDATE SKIP LOCKED, locked_until reclaim, lifespan stop).
한 tick 에 두 pass:

  (1) Materialize — active plan(next_eligible_at<=now) 스캔 → source intent fresh 로드(종료연동 HIGH-2)
      → occurrence-math(순수, recall_occurrence) → 하드가드(순수, recall_guards) → outbox 1 row INSERT.
      per-owner advisory lock 으로 두 워커 동시 카운트 방지(schema.md §4 #5).
  (2) Send — fire_at 도달 outbox claim(plan active JOIN 보장, §4 #2) → dry-run/실발송 → APNs 410 분류.

킬스위치 recall_worker_enabled=False 면 루프는 no-op(기동은 함). dry-run 기본 True(발송 0 튜닝, §6/§7).
occurrence-math·가드는 순수함수로 분리(DB 무관·단위테스트 가능). 정본 schema.md / notification-agent.md.
"""

import asyncio
from datetime import UTC, datetime, timedelta
from typing import Any, cast
from uuid import UUID, uuid4

from sqlalchemy import CursorResult, bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings, get_settings
from app.core.db import get_session_factory
from app.core.deps import get_apns_client
from app.core.logging import get_logger
from app.modules.intents.domain.lifecycle_policy import (
    KNOWLEDGE_ACTIVE_DAYS,
    KNOWLEDGE_DECAY_DAYS,
)
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    IntentInstance,
)
from app.modules.notifications.application.recall_guards import (
    GUARD_ALLOW,
    GUARD_DEFER,
    GUARD_SKIP,
    GuardDecision,
    check_dismiss_cooldown,
    check_track_b_yield,
)
from app.modules.notifications.application.recall_occurrence import (
    KST,
    SPACED_DONE,
    SPACED_WAIT,
    NextOccurrence,
    SpacedState,
    next_recurring_occurrence,
    next_relative_occurrence,
    next_spaced_occurrence,
    resolve_anchor_time,
)
from app.modules.notifications.application.repositories import make_push_token_repository
from app.modules.notifications.application.send_recall_notification import (
    RecallNotification,
    SendRecallNotification,
)
from app.modules.notifications.domain.ports import APNsClient
from app.modules.notifications.domain.recall_plan import (
    AnchorKind,
    PlanKind,
    RecallPlanStages,
    Stage,
    TriggerType,
    outbox_kind_for,
)
from app.shared.intent import Intent

log = get_logger("notifications.recall_worker")

# materialize 스캔/발송 claim 배치 상한.
_MATERIALIZE_BATCH = 50
# materialize 시 과거 anchor 유예 — 이 시각을 넘겨 놓친 relative occurrence 는 stale(만료) 처리.
_STALE_GRACE = timedelta(hours=6)
# 반응 대기(spaced) plan 의 bounded 재폴 — 반응(opened)이 들어오면 다음 tick 에서 전진하도록.
# FAR_FUTURE(영구 수면)로 두면 recurring 주기·spaced 전진이 정지한다(P1#2).
_SPACED_REPOLL = timedelta(days=1)
# recurring lazy lookahead(P2): until/max 없는 recurring 이 tick 마다 미래 occurrence 를 줄줄이 pending
# 으로 미리 박지 않게, 다음 occurrence 가 이 창 안(due 임박)일 때만 materialize. 밖이면 그 fire_at 까지
# next_eligible_at 으로 대기(진짜 lazy). relative 단발은 미래 fire_at pending 큐잉이 정상이라 제외.
_RECURRING_LOOKAHEAD = timedelta(minutes=15)
# 발송 transient 실패 backoff.
_SEND_BASE_BACKOFF = timedelta(minutes=5)
_SEND_MAX_ATTEMPTS = 5
# knowledge 의미 lifecycle 시간 전이 주기 — 전체 스캔이라 매 poll 이 아니라 하루 1회.
_DECAY_INTERVAL = timedelta(days=1)


class NotificationWorker:
    def __init__(self) -> None:
        self._stop = asyncio.Event()
        self._last_decay_at: datetime | None = None

    async def run_forever(self) -> None:
        settings = get_settings()
        session_factory = get_session_factory()
        poll = settings.recall_worker_poll_interval_seconds
        while not self._stop.is_set():
            if not settings.recall_worker_enabled:
                # 킬스위치 — 기동은 하되 루프는 no-op(schema/notification-agent §7).
                await asyncio.sleep(poll)
                continue
            try:
                await self._maybe_decay_knowledge(session_factory)
                await self._materialize_pass(session_factory, settings)
                await self._send_pass(session_factory, settings)
            except Exception as exc:  # noqa: BLE001 - 한 tick 실패가 루프를 죽이지 않게.
                log.warning("recall_worker.tick_failed", exception=str(exc), exc_info=True)
            await asyncio.sleep(poll)

    async def stop(self) -> None:
        self._stop.set()

    # ---------- (0) Knowledge decay pass ----------

    async def _maybe_decay_knowledge(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        """knowledge instance 의 시간 기반 의미 lifecycle 전이 — 하루 1회(전체 스캔).

        ``active → decaying → reviewRequested``. **시계 = ``updated_at``**(= 마지막 상태변경 시각). spaced
        회수 트랙(트랙A)은 decaying/reviewRequested knowledge 만 피드에 노출하므로(``get_recall_feed``),
        이 전이가 없으면 instance 가 영원히 active 라 spaced 알림을 열어도 항상 빈 피드였다(트랙A 무력, HIGH-2).

        ``updated_at`` 을 시계로 쓰는 이유: 회수 소생(opened+spaced → decaying/reviewRequested→active,
        `record_recall_reaction`)이 ``update_instance_lifecycle`` 로 updated_at 을 now 로 리셋하므로,
        소생된 knowledge 는 다시 30일 active 를 보장받는다(created_at 시계면 소생 직후 즉시 재decay). §5.4
        의미("마지막 회수 후 30일 → decaying", "decaying 진입 후 180일 → reviewRequested")와 정합 —
        active→decaying 이 updated_at 을 now 로 갱신해 "decaying 진입 시각" 도 같은 컬럼이 된다.

        두 UPDATE 는 같은 트랜잭션 — 오래 방치된 active 는 먼저 decaying(updated_at=now) 으로만 가고,
        이번에 막 decaying 된 행은 review_cutoff(now-180) 밖이라 같은 패스에서 review 로 안 넘어간다(정상).
        전이 합법성은 ``lifecycle_policy`` 가 정본(test_lifecycle_policy 가 불변식 고정).
        정본: DOMAIN_DESIGN §5.4 / `intents.domain.lifecycle_policy`.
        """
        now = datetime.now(UTC)
        if self._last_decay_at is not None and now - self._last_decay_at < _DECAY_INTERVAL:
            return
        self._last_decay_at = now
        active_cutoff = now - timedelta(days=KNOWLEDGE_ACTIVE_DAYS)
        review_cutoff = now - timedelta(days=KNOWLEDGE_DECAY_DAYS)
        async with session_factory() as session:
            to_decaying = cast(
                CursorResult[Any],
                await session.execute(
                    text(
                        """
                        UPDATE intent_instances
                        SET lifecycle_kind=:decaying, updated_at=now()
                        WHERE intent_type=:knowledge AND lifecycle_kind=:active AND updated_at < :cutoff
                        """
                    ).bindparams(
                        bindparam("decaying", InstanceLifecycleKind.DECAYING.value),
                        bindparam("knowledge", Intent.KNOWLEDGE.value),
                        bindparam("active", InstanceLifecycleKind.ACTIVE.value),
                        bindparam("cutoff", active_cutoff),
                    )
                ),
            )
            to_review = cast(
                CursorResult[Any],
                await session.execute(
                    text(
                        """
                        UPDATE intent_instances
                        SET lifecycle_kind=:review, updated_at=now()
                        WHERE intent_type=:knowledge AND lifecycle_kind=:decaying AND updated_at < :cutoff
                        """
                    ).bindparams(
                        bindparam("review", InstanceLifecycleKind.REVIEW_REQUESTED.value),
                        bindparam("knowledge", Intent.KNOWLEDGE.value),
                        bindparam("decaying", InstanceLifecycleKind.DECAYING.value),
                        bindparam("cutoff", review_cutoff),
                    )
                ),
            )
            await session.commit()
        decayed = to_decaying.rowcount or 0
        reviewed = to_review.rowcount or 0
        if decayed or reviewed:
            log.info("recall_worker.knowledge_decayed", to_decaying=decayed, to_review_requested=reviewed)

    # ---------- (1) Materialize pass ----------

    async def _materialize_pass(
        self, session_factory: async_sessionmaker[AsyncSession], settings: Settings
    ) -> None:
        now = datetime.now(UTC)
        async with session_factory() as scan_session:
            rows = (
                await scan_session.execute(
                    text(
                        """
                        SELECT id, owner_id, source_intent_id, source_item_id, plan_kind, stages
                        FROM notification_plan
                        WHERE status='active' AND next_eligible_at IS NOT NULL
                          AND next_eligible_at <= :now
                        ORDER BY next_eligible_at
                        LIMIT :limit
                        """
                    ).bindparams(bindparam("now", now), bindparam("limit", _MATERIALIZE_BATCH))
                )
            ).all()
            # supersede 청소(§4-2): superseded plan 의 pending/deferred outbox 를 skipped(superseded).
            await scan_session.execute(
                text(
                    """
                    UPDATE notification_outbox o
                    SET status='skipped', skip_reason='superseded', updated_at=now()
                    WHERE o.status IN ('pending','deferred')
                      AND o.plan_id IN (SELECT id FROM notification_plan WHERE status='superseded')
                    """
                )
            )
            await scan_session.commit()

        for row in rows:
            try:
                async with session_factory() as session:
                    await self._materialize_one_plan(session, settings, plan_row=row, now=now)
                    await session.commit()
            except Exception as exc:  # noqa: BLE001 - plan 단위 격리.
                log.warning(
                    "recall_worker.materialize_failed",
                    plan_id=str(row.id),
                    exception=str(exc),
                    exc_info=True,
                )

    async def _materialize_one_plan(
        self, session: AsyncSession, settings: Settings, *, plan_row: Any, now: datetime
    ) -> None:
        owner_id: UUID = plan_row.owner_id
        plan_id: UUID = plan_row.id
        source_intent_id: UUID = plan_row.source_intent_id
        plan_kind = PlanKind(plan_row.plan_kind)

        # per-owner 직렬화(§4 #5) — 두 워커가 같은 owner cap 을 동시에 세지 못하게.
        await session.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:owner))").bindparams(owner=str(owner_id))
        )

        # source intent fresh 로드 + 종료연동(HIGH-2).
        item = (
            await GetMochiItemForOwner(repository=make_mochi_item_repository(session)).execute(
                owner_id=owner_id, mochi_item_id=plan_row.source_item_id
            )
            if plan_row.source_item_id
            else None
        )
        instance = self._find_instance(item, source_intent_id)
        if instance is None or instance.lifecycle.kind is InstanceLifecycleKind.ARCHIVED:
            await self._cancel_plan_intent_archived(session, plan_id=plan_id, owner_id=owner_id, now=now)
            return

        try:
            stages_model = RecallPlanStages.model_validate(plan_row.stages).validate_for(plan_kind)
        except Exception as exc:  # noqa: BLE001 - 손상된 stages: plan 을 cancelled 로 닫는다.
            log.warning("recall_worker.stages_invalid", plan_id=str(plan_id), exception=str(exc))
            await self._cancel_plan_intent_archived(session, plan_id=plan_id, owner_id=owner_id, now=now)
            return

        # deferred 회생(P1#1): cap/야간/트랙B 로 미뤄진 occurrence 를 next_retry_at 도달 시 재평가 →
        # 가드 통과면 pending 으로 전이, 아니면 재-defer/만료. 이게 없으면 deferred 가 영구 소실된다.
        await self._reactivate_deferred(session, settings, plan_row=plan_row, now=now)

        # 다음 occurrence 계산(stage 별). 첫 materialize 가능한 1건만 처리(가드/INSERT).
        occ, stage = await self._compute_next(
            session, plan_id, plan_kind, stages_model.stages, item, instance, now
        )
        if occ is None or stage is None:
            # 모든 stage 소진/대기/종료. spaced wait/done 은 _compute_next 가 plan 상태를 갱신했다.
            await self._reschedule_or_finish(
                session, plan_id, plan_kind, stages_model.stages, item, instance, now
            )
            return

        kind = outbox_kind_for(plan_kind).value
        # 과거 occurrence stale skip(P1#2): _compute_next 가 과거 target 에 expires_at(과거)인 occ 를
        # 반환(stale 신호)했는데 가드만 거쳐 status='pending' 으로 INSERT 하면 _claim_next(expires_at>now)
        # 가 영원히 claim 못 해 plan 이 영구 재폴된다. 가드 실행 전에 terminal skip(stale)+즉시 재평가.
        if occ.expires_at is not None and occ.expires_at <= now:
            await self._insert_outbox(
                session,
                plan_row=plan_row,
                occ=occ,
                kind=kind,
                fire_at=occ.fire_at,
                status="skipped",
                skip_reason="stale",
                instance=instance,
                stage=stage,
            )
            await self._set_next_eligible(session, plan_id, now + timedelta(seconds=1))
            return

        # recurring lazy 게이팅(P2): 다음 recurring occurrence 가 아직 lookahead 밖(미래)이면 미리
        # pending 으로 박지 말고 그 fire_at 까지 대기. relative 단발은 미래 큐잉이 정상이라 제외.
        if stage.trigger.type is TriggerType.RECURRING and occ.fire_at > now + _RECURRING_LOOKAHEAD:
            await self._set_next_eligible(session, plan_id, occ.fire_at)
            return

        # 하드 가드 — materialize 직전.
        decision = await self._run_guards(
            session,
            settings,
            owner_id=owner_id,
            source_intent_id=source_intent_id,
            kind=kind,
            fire_at=occ.fire_at,
            now=now,
        )
        fire_at = decision.fire_at or occ.fire_at

        if decision.action == GUARD_SKIP:
            await self._insert_outbox(
                session,
                plan_row=plan_row,
                occ=occ,
                kind=kind,
                fire_at=fire_at,
                status="skipped",
                skip_reason=decision.skip_reason,
                instance=instance,
                stage=stage,
            )
            await self._set_next_eligible(session, plan_id, now + timedelta(seconds=1))
            return
        if decision.action == GUARD_DEFER:
            await self._insert_outbox(
                session,
                plan_row=plan_row,
                occ=occ,
                kind=kind,
                fire_at=fire_at,
                status="deferred",
                skip_reason=decision.skip_reason,
                instance=instance,
                stage=stage,
                next_retry_at=decision.next_retry_at,
            )
            await self._set_next_eligible(
                session, plan_id, decision.next_retry_at or now + timedelta(minutes=30)
            )
            return

        # allow — pending materialize.
        await self._insert_outbox(
            session,
            plan_row=plan_row,
            occ=occ,
            kind=kind,
            fire_at=fire_at,
            status="pending",
            skip_reason=None,
            instance=instance,
            stage=stage,
        )
        # 다음 평가는 이 occurrence 발송 후 — 곧바로 재평가(다음 stage·occurrence).
        await self._set_next_eligible(session, plan_id, now + timedelta(seconds=1))

    @staticmethod
    def _find_instance(item: MochiItem | None, source_intent_id: UUID) -> IntentInstance | None:
        if item is None:
            return None
        return next((i for i in item.intent_instances if i.id == source_intent_id), None)

    async def _cancel_plan_intent_archived(
        self, session: AsyncSession, *, plan_id: UUID, owner_id: UUID, now: datetime
    ) -> None:
        # 종료연동(HIGH-2): intent 없음/archived → plan cancelled + pending/deferred outbox skipped(cancelled).
        # skip_reason='cancelled' 는 plan 취소(intent_archived·user stop) terminal — 재평가 교체('superseded')와
        # 구별(P1#3). 구체 사유는 plan.cancel_reason 이 보유. schema.md §2 어휘.
        await session.execute(
            text(
                """
                UPDATE notification_plan
                SET status='cancelled', cancel_reason='intent_archived', cancelled_at=:now, updated_at=now()
                WHERE id=:id AND owner_id=:owner AND status='active'
                """
            ).bindparams(bindparam("now", now), bindparam("id", plan_id), bindparam("owner", owner_id))
        )
        await session.execute(
            text(
                """
                UPDATE notification_outbox
                SET status='skipped', skip_reason='cancelled', updated_at=now()
                WHERE plan_id=:id AND status IN ('pending','deferred')
                """
            ).bindparams(bindparam("id", plan_id))
        )
        log.info("recall_worker.plan_cancelled", plan_id=str(plan_id), reason="intent_archived")

    async def _compute_next(
        self,
        session: AsyncSession,
        plan_id: UUID,
        plan_kind: PlanKind,
        stages: list[Stage],
        item: MochiItem | None,
        instance: IntentInstance,
        now: datetime,
    ) -> tuple[NextOccurrence | None, Stage | None]:
        """첫 materialize 가능한 (occurrence, stage) 1건. 없으면 (None, None).

        relative: 이미 materialize 됐으면 skip. recurring: 마지막 occurrence_seq 다음. spaced: 반응 기준 전진.
        """
        saved_at = item.created_at if item is not None else now
        for stage in stages:
            ttype = stage.trigger.type
            if ttype is TriggerType.RELATIVE:
                anchor_time = self._resolve_relative_anchor(stage, instance, saved_at)
                if anchor_time is None:
                    continue
                already = await self._occurrence_exists(session, plan_id, stage.seq, 1)
                occ = next_relative_occurrence(
                    stage=stage,
                    anchor_time=anchor_time,
                    now=now,
                    grace=_STALE_GRACE,
                    already_materialized=already,
                )
                if occ is not None:
                    return occ, stage
            elif ttype is TriggerType.RECURRING:
                last_seq = await self._max_occurrence_seq(session, plan_id, stage.seq)
                until_time = self._resolve_until(stage, instance)
                occ = next_recurring_occurrence(
                    stage=stage, base=saved_at, last_occurrence_seq=last_seq, until_time=until_time
                )
                if occ is not None and not await self._occurrence_exists(
                    session, plan_id, stage.seq, occ.occurrence_seq
                ):
                    return occ, stage
            elif ttype is TriggerType.SPACED:
                last = await self._last_spaced_state(session, plan_id, stage.seq)
                result = next_spaced_occurrence(stage=stage, base=saved_at, last=last)
                if isinstance(result, NextOccurrence) and not await self._occurrence_exists(
                    session, plan_id, stage.seq, result.occurrence_seq
                ):
                    return result, stage
                # SPACED_WAIT / SPACED_DONE / None → 이 stage 는 materialize 안 함(상위가 reschedule/finish).
        return None, None

    def _resolve_relative_anchor(
        self, stage: Stage, instance: IntentInstance, saved_at: datetime
    ) -> datetime | None:
        anchor = stage.trigger.anchor or AnchorKind.SAVED_AT
        p = instance.payload
        # event_date 는 date(+time) 결합. deadline 은 단일 문자열.
        event_value = p.date
        if anchor is AnchorKind.EVENT_DATE and p.date and p.time:
            event_value = f"{p.date}T{p.time}"
        return resolve_anchor_time(
            anchor=anchor, deadline_value=p.deadline, event_date_value=event_value, saved_at=saved_at
        )

    def _resolve_until(self, stage: Stage, instance: IntentInstance) -> datetime | None:
        """recurring 의 until_anchor → 종료 시각(UTC). 없으면 None(무한)."""
        if stage.trigger.until_anchor is None:
            return None
        p = instance.payload
        # event_date until 도 relative anchor 처럼 date+time 결합(P2#2) — time 을 버리면 마감 당일 일찍 끊긴다.
        event_value = f"{p.date}T{p.time}" if (p.date and p.time) else p.date
        return resolve_anchor_time(
            anchor=stage.trigger.until_anchor,
            deadline_value=p.deadline,
            event_date_value=event_value,
            saved_at=datetime.now(UTC),
        )

    async def _run_guards(
        self,
        session: AsyncSession,
        settings: Settings,
        *,
        owner_id: UUID,
        source_intent_id: UUID,
        kind: str,
        fire_at: datetime,
        now: datetime,
    ) -> GuardDecision:
        # 1) dismiss cooldown(plan 경계 넘음, source_intent 기준).
        last_dismissed = (
            await session.execute(
                text(
                    "SELECT MAX(dismissed_at) FROM notification_outbox "
                    "WHERE source_intent_id=:sid AND dismissed_at IS NOT NULL"
                ).bindparams(sid=source_intent_id)
            )
        ).scalar()
        cooldown = check_dismiss_cooldown(
            last_dismissed_at=last_dismissed, now=now, cooldown_days=settings.recall_dismiss_cooldown_days
        )
        if cooldown is not None:
            return cooldown

        # 2) 트랙B 양보 — 같은 KST day 에 deadline push 가 있나.
        fire_kst_date = fire_at.astimezone(KST).date()
        has_deadline = (
            await session.execute(
                text(
                    """
                    SELECT EXISTS(
                      SELECT 1 FROM notification_outbox
                      WHERE owner_id=:owner AND kind='deadline'
                        AND status IN ('pending','sent')
                        AND (fire_at AT TIME ZONE 'Asia/Seoul')::date = :d
                    )
                    """
                ).bindparams(owner=owner_id, d=fire_kst_date)
            )
        ).scalar()
        track_b = check_track_b_yield(
            kind=kind, has_deadline_push_same_day=bool(has_deadline), fire_at=fire_at
        )
        if track_b is not None:
            return track_b

        return GuardDecision(action=GUARD_ALLOW, fire_at=fire_at)

    async def _reactivate_deferred(
        self, session: AsyncSession, settings: Settings, *, plan_row: Any, now: datetime
    ) -> None:
        """next_retry_at 도달 deferred occurrence 재평가(P1#1) — 영구 소실 방지.

        만료(expires) 지났으면 stale terminal. 아니면 next_retry_at 시각으로 가드 재실행 →
        통과(ALLOW)면 pending 전이(가드가 다시 shift 했을 수 있는 fire_at), 여전히 DEFER 면 next_retry_at
        갱신, SKIP 이면 terminal. cap 은 재평가 날짜 기준으로 다시 카운트된다(advisory lock 하 직렬).
        """
        rows = (
            await session.execute(
                text(
                    """
                    SELECT id, kind, fire_at, expires_at, next_retry_at
                    FROM notification_outbox
                    WHERE plan_id=:p AND status='deferred'
                      AND next_retry_at IS NOT NULL AND next_retry_at <= :now
                    ORDER BY next_retry_at
                    """
                ).bindparams(bindparam("p", plan_row.id), bindparam("now", now))
            )
        ).all()
        for r in rows:
            if r.expires_at is not None and r.expires_at <= now:
                await self._update_outbox_status(session, r.id, status="skipped", skip_reason="stale")
                continue
            candidate_fire = r.next_retry_at if r.next_retry_at > now else now
            decision = await self._run_guards(
                session,
                settings,
                owner_id=plan_row.owner_id,
                source_intent_id=plan_row.source_intent_id,
                kind=r.kind,
                fire_at=candidate_fire,
                now=now,
            )
            if decision.action == GUARD_ALLOW:
                await session.execute(
                    text(
                        "UPDATE notification_outbox SET status='pending', fire_at=:f, skip_reason=NULL, "
                        "next_retry_at=NULL, updated_at=now() WHERE id=:id AND status='deferred'"
                    ).bindparams(bindparam("f", decision.fire_at or candidate_fire), bindparam("id", r.id))
                )
            elif decision.action == GUARD_DEFER:
                await session.execute(
                    text(
                        "UPDATE notification_outbox SET next_retry_at=:r, skip_reason=:sr, updated_at=now() "
                        "WHERE id=:id AND status='deferred'"
                    ).bindparams(
                        bindparam("r", decision.next_retry_at),
                        bindparam("sr", decision.skip_reason),
                        bindparam("id", r.id),
                    )
                )
            else:  # GUARD_SKIP
                await self._update_outbox_status(
                    session, r.id, status="skipped", skip_reason=decision.skip_reason
                )

    async def _update_outbox_status(
        self, session: AsyncSession, outbox_id: int, *, status: str, skip_reason: str | None
    ) -> None:
        await session.execute(
            text(
                "UPDATE notification_outbox SET status=:s, skip_reason=:r, next_retry_at=NULL, updated_at=now() "
                "WHERE id=:id"
            ).bindparams(bindparam("s", status), bindparam("r", skip_reason), bindparam("id", outbox_id))
        )

    async def _insert_outbox(
        self,
        session: AsyncSession,
        *,
        plan_row: Any,
        occ: NextOccurrence,
        kind: str,
        fire_at: datetime,
        status: str,
        skip_reason: str | None,
        instance: IntentInstance,
        stage: Stage,
        next_retry_at: datetime | None = None,
    ) -> None:
        title, body = _render_content(stage, instance)
        collapse = (
            str(plan_row.source_intent_id) if plan_row.source_intent_id else f"{plan_row.id}:{occ.stage_seq}"
        )[:64]
        # owner_id 복사(§4 #3). UNIQUE(plan_id,stage_seq,occurrence_seq) 가 중복 차단(IntegrityError 시 plan 단위 격리).
        # event_id 명시 생성 — raw text() INSERT 는 ORM 의 insert_default=uuid4(orm.py) 를 우회하고
        # event_id 는 NOT NULL·DB default 없음(migration 0023)이라 여기서 채워야 NotNullViolation 안 난다.
        await session.execute(
            text(
                """
                INSERT INTO notification_outbox
                  (event_id, owner_id, kind, fire_at, title, body, plan_id, stage_seq, occurrence_seq,
                   source_item_id, source_intent_id, expires_at, collapse_id, status, skip_reason, next_retry_at)
                VALUES
                  (:event_id, :owner, :kind, :fire_at, :title, :body, :plan_id, :stage_seq, :occ_seq,
                   :item_id, :intent_id, :expires_at, :collapse, :status, :skip_reason, :next_retry_at)
                ON CONFLICT (plan_id, stage_seq, occurrence_seq) WHERE plan_id IS NOT NULL DO NOTHING
                """
            ).bindparams(
                bindparam("event_id", uuid4()),
                bindparam("owner", plan_row.owner_id),
                bindparam("kind", kind),
                bindparam("fire_at", fire_at),
                bindparam("title", title),
                bindparam("body", body),
                bindparam("plan_id", plan_row.id),
                bindparam("stage_seq", occ.stage_seq),
                bindparam("occ_seq", occ.occurrence_seq),
                bindparam("item_id", plan_row.source_item_id),
                bindparam("intent_id", plan_row.source_intent_id),
                bindparam("expires_at", occ.expires_at),
                bindparam("collapse", collapse),
                bindparam("status", status),
                bindparam("skip_reason", skip_reason),
                bindparam("next_retry_at", next_retry_at),
            )
        )
        log.info(
            "recall_worker.materialized",
            plan_id=str(plan_row.id),
            stage_seq=occ.stage_seq,
            occurrence_seq=occ.occurrence_seq,
            kind=kind,
            status=status,
            skip_reason=skip_reason,
            fire_at=fire_at.isoformat(),
        )

    async def _reschedule_or_finish(
        self,
        session: AsyncSession,
        plan_id: UUID,
        plan_kind: PlanKind,
        stages: list[Stage],
        item: MochiItem | None,
        instance: IntentInstance,
        now: datetime,
    ) -> None:
        """다음 occurrence 가 없는 plan — spaced 종료/대기, 또는 모든 stage 소진 → done."""
        saved_at = item.created_at if item is not None else now
        any_active = False  # 더 발송할 게 남았나(대기 포함)
        for stage in stages:
            if stage.trigger.type is TriggerType.SPACED:
                last = await self._last_spaced_state(session, plan_id, stage.seq)
                result = next_spaced_occurrence(stage=stage, base=saved_at, last=last)
                if result == SPACED_DONE:
                    continue  # 이 stage terminal
                if result == SPACED_WAIT:
                    any_active = True  # 반응 대기 — plan 살아있음
                elif result is not None:
                    any_active = True  # materialize 가능한데 가드로 빠졌을 수 있음
            elif stage.trigger.type is TriggerType.RECURRING:
                last_seq = await self._max_occurrence_seq(session, plan_id, stage.seq)
                until_time = self._resolve_until(stage, instance)
                if (
                    next_recurring_occurrence(
                        stage=stage, base=saved_at, last_occurrence_seq=last_seq, until_time=until_time
                    )
                    is not None
                ):
                    any_active = True
            elif stage.trigger.type is TriggerType.RELATIVE:
                if not await self._occurrence_exists(session, plan_id, stage.seq, 1):
                    any_active = True

        # 미발송(pending/deferred) outbox 가 남아 있으면 done 아님 — relative 단발이 pending(미발송)인데
        # occurrence_exists 만 보고 done 처리되던 조기 종료 버그 방지(P1#2).
        if not any_active and await self._has_unsent_outbox(session, plan_id):
            any_active = True

        if any_active:
            # FAR_FUTURE(영구 수면) 금지 — pending fire_at / deferred next_retry_at 중 가장 이른 시각으로
            # bounded 재폴(recurring 주기·spaced 전진 정지 방지, P1#2). 없으면 spaced 반응대기 → 1일 재폴.
            await self._set_next_eligible(
                session, plan_id, await self._earliest_pending_or_retry(session, plan_id, now)
            )
        else:
            await session.execute(
                text(
                    "UPDATE notification_plan SET status='done', next_eligible_at=NULL, updated_at=now() "
                    "WHERE id=:id AND status='active'"
                ).bindparams(id=plan_id)
            )
            log.info("recall_worker.plan_done", plan_id=str(plan_id))

    async def _set_next_eligible(self, session: AsyncSession, plan_id: UUID, when: datetime) -> None:
        await session.execute(
            text(
                "UPDATE notification_plan SET next_eligible_at=:w, updated_at=now() WHERE id=:id"
            ).bindparams(bindparam("w", when), bindparam("id", plan_id))
        )

    async def _has_unsent_outbox(self, session: AsyncSession, plan_id: UUID) -> bool:
        """plan 에 아직 발송 전(pending/deferred) outbox 가 있나 — 조기 done 방지(P1#2)."""
        return bool(
            (
                await session.execute(
                    text(
                        "SELECT 1 FROM notification_outbox WHERE plan_id=:p "
                        "AND status IN ('pending','deferred') LIMIT 1"
                    ).bindparams(p=plan_id)
                )
            ).first()
        )

    async def _earliest_pending_or_retry(
        self, session: AsyncSession, plan_id: UUID, now: datetime
    ) -> datetime:
        """plan 의 다음 평가 시각 — pending fire_at / deferred next_retry_at 중 최솟값(bounded).

        둘 다 없으면 spaced 반응 대기로 보고 1일 재폴(반응이 들어오면 다음 tick 에서 전진). 과거면 즉시.
        """
        value = (
            await session.execute(
                text(
                    """
                    SELECT MIN(t) FROM (
                      SELECT fire_at AS t FROM notification_outbox
                        WHERE plan_id=:p AND status='pending'
                      UNION ALL
                      SELECT next_retry_at FROM notification_outbox
                        WHERE plan_id=:p AND status='deferred' AND next_retry_at IS NOT NULL
                    ) x
                    """
                ).bindparams(p=plan_id)
            )
        ).scalar()
        if value is None:
            return now + _SPACED_REPOLL
        return value if value > now else now + timedelta(seconds=1)

    async def _occurrence_exists(
        self, session: AsyncSession, plan_id: UUID, stage_seq: int, occurrence_seq: int
    ) -> bool:
        return bool(
            (
                await session.execute(
                    text(
                        "SELECT 1 FROM notification_outbox "
                        "WHERE plan_id=:p AND stage_seq=:s AND occurrence_seq=:o LIMIT 1"
                    ).bindparams(p=plan_id, s=stage_seq, o=occurrence_seq)
                )
            ).first()
        )

    async def _max_occurrence_seq(self, session: AsyncSession, plan_id: UUID, stage_seq: int) -> int | None:
        # skipped 포함 전체 MAX(P1#3): skipped 를 빼면 recurring occ N 이 SKIP terminal(dismiss_cooldown
        # 등) 됐을 때 같은 N 을 재계산 → _occurrence_exists True → occ N+1 로 못 넘어가 영구 정지.
        # 중복 차단은 _occurrence_exists + UNIQUE(plan_id,stage_seq,occurrence_seq) 가 이미 담당.
        value = (
            await session.execute(
                text(
                    "SELECT MAX(occurrence_seq) FROM notification_outbox WHERE plan_id=:p AND stage_seq=:s"
                ).bindparams(p=plan_id, s=stage_seq)
            )
        ).scalar()
        return int(value) if value is not None else None

    async def _last_spaced_state(
        self, session: AsyncSession, plan_id: UUID, stage_seq: int
    ) -> SpacedState | None:
        # status != 'skipped' 가 기본(stale/cancelled/superseded skip 은 전진 신호 아님)이나,
        # user_veto("이번 회차만 건너뛰기")는 예외 — 그 칸을 last 로 인식해 다음 칸으로 전진시킨다.
        row = (
            await session.execute(
                text(
                    """
                    SELECT occurrence_seq, sent_at, opened_at, dismissed_at, fire_at, skip_reason
                    FROM notification_outbox
                    WHERE plan_id=:p AND stage_seq=:s
                      AND (status != 'skipped' OR skip_reason = 'user_veto')
                    ORDER BY occurrence_seq DESC LIMIT 1
                    """
                ).bindparams(p=plan_id, s=stage_seq)
            )
        ).first()
        if row is None:
            return None
        return SpacedState(
            occurrence_seq=row.occurrence_seq,
            sent_at=row.sent_at,
            opened_at=row.opened_at,
            dismissed_at=row.dismissed_at,
            fire_at=row.fire_at,
            vetoed=row.skip_reason == "user_veto",
        )

    # ---------- (2) Send pass ----------

    async def _send_pass(self, session_factory: async_sessionmaker[AsyncSession], settings: Settings) -> None:
        apns = get_apns_client()
        for _ in range(_MATERIALIZE_BATCH):
            async with session_factory() as session:
                claimed = await self._claim_next(session, settings)
            if claimed is None:
                return
            await self._send_one(session_factory, settings, apns, claimed)

    async def _claim_next(self, session: AsyncSession, settings: Settings) -> "ClaimedNotification | None":
        now = datetime.now(UTC)
        lock_until = now + timedelta(seconds=settings.recall_worker_lock_seconds)
        sql = text(
            """
            UPDATE notification_outbox
            SET locked_until=:lock_until, attempts=attempts+1
            WHERE id = (
                SELECT id FROM notification_outbox
                WHERE status='pending' AND fire_at <= :now
                  AND (locked_until IS NULL OR locked_until < :now)
                  AND (expires_at IS NULL OR expires_at > :now)
                  AND (
                       plan_id IS NULL
                       OR EXISTS(SELECT 1 FROM notification_plan p WHERE p.id=plan_id AND p.status='active')
                      )
                ORDER BY fire_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING id, event_id, owner_id, kind, title, body, source_item_id,
                      source_intent_id, collapse_id, attempts, expires_at
            """
        ).bindparams(bindparam("lock_until", lock_until), bindparam("now", now))
        row = (await session.execute(sql)).one_or_none()
        await session.commit()
        if row is None:
            return None
        return ClaimedNotification(
            id=row.id,
            event_id=row.event_id,
            owner_id=row.owner_id,
            kind=row.kind,
            title=row.title,
            body=row.body,
            source_item_id=row.source_item_id,
            source_intent_id=row.source_intent_id,
            collapse_id=row.collapse_id,
            attempts=row.attempts,
        )

    async def _recall_push_enabled(
        self, session_factory: async_sessionmaker[AsyncSession], owner_id: UUID
    ) -> bool:
        """``users.notify_recall_enabled`` 조회 — 명시적 False 만 off (행 없음은 on 취급, 0028)."""
        async with session_factory() as session:
            enabled = (
                await session.execute(
                    text("SELECT notify_recall_enabled FROM users WHERE id=:owner").bindparams(
                        bindparam("owner", owner_id)
                    )
                )
            ).scalar_one_or_none()
        return enabled is not False

    async def _send_one(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        settings: Settings,
        apns: APNsClient | None,
        claimed: "ClaimedNotification",
    ) -> None:
        # 사용자 전역 회수 알림 선호 off → skipped(preference_off) terminal (0028). 발송 시점 게이트만 —
        # plan/materialize 불변이라 다시 켜면 다음 fire_at 부터 재개되고, spaced 전진 필터(user_veto 만
        # 전진 인정)에 안 걸려 회차도 소모하지 않는다. dry-run 보다 앞 — off 사용자는 튜닝 로그에도 안 남긴다.
        if not await self._recall_push_enabled(session_factory, claimed.owner_id):
            log.info(
                "recall_worker.preference_off",
                event_id=str(claimed.event_id),
                owner_id=str(claimed.owner_id),
                kind=claimed.kind,
            )
            await self._close(session_factory, claimed.id, status="skipped", skip_reason="preference_off")
            return

        # dry-run(기본 True, §6/§7): 실제 APNs 호출 없이 payload 로깅 + skipped(dry_run) terminal.
        if settings.recall_notifications_dry_run:
            log.info(
                "recall_worker.dry_run",
                event_id=str(claimed.event_id),
                owner_id=str(claimed.owner_id),
                kind=claimed.kind,
                title=claimed.title,
                body=claimed.body,
                source_item_id=str(claimed.source_item_id) if claimed.source_item_id else None,
                source_intent_id=str(claimed.source_intent_id) if claimed.source_intent_id else None,
                route_type="detail",
            )
            await self._close(session_factory, claimed.id, status="skipped", skip_reason="dry_run")
            return

        async with session_factory() as session:
            sender = SendRecallNotification(tokens=make_push_token_repository(session), apns=apns)
            result = await sender.run(
                owner_id=claimed.owner_id,
                notification=RecallNotification(
                    event_id=claimed.event_id,
                    title=claimed.title,
                    body=claimed.body,
                    kind=claimed.kind,
                    source_item_id=claimed.source_item_id,
                    source_intent_id=claimed.source_intent_id,
                    collapse_id=claimed.collapse_id,
                ),
            )
            # 무효 토큰 삭제(codex-5) — 같은 세션.
            for tok in result.invalid_tokens:
                await make_push_token_repository(session).delete(token=tok)
            await session.commit()

        if result.sent:
            await self._close(session_factory, claimed.id, status="sent", set_sent_at=True)
            return
        if not result.had_tokens or (result.invalid_tokens and result.transient_error is None):
            # 유효 토큰 0(처음부터 없음 또는 전부 무효) → dead_letter(재시도 안 함).
            await self._close(session_factory, claimed.id, status="dead_letter", skip_reason="no_valid_token")
            return
        # transient(5xx/timeout) → pending 유지 + backoff. attempts>=MAX → dead_letter.
        if claimed.attempts >= _SEND_MAX_ATTEMPTS:
            await self._close(
                session_factory, claimed.id, status="dead_letter", last_error=result.transient_error
            )
            return
        backoff = _SEND_BASE_BACKOFF * (2 ** (claimed.attempts - 1))
        retry_at = datetime.now(UTC) + backoff
        await self._defer_transient(session_factory, claimed.id, retry_at, result.transient_error)

    async def _close(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        outbox_id: int,
        *,
        status: str,
        skip_reason: str | None = None,
        last_error: str | None = None,
        set_sent_at: bool = False,
    ) -> None:
        async with session_factory() as session:
            sent_clause = ", sent_at=now()" if set_sent_at else ""
            # status='pending' 가드 — claim 은 locked_until 만 잡고 status 를 안 바꾸므로(행 lock 없음)
            # 발송 진행 중 사용자 반응(피드 stop/open)이 행을 skipped 로 종결할 수 있다. 무가드면
            # 그 종결을 sent 로 되엎어 opened_at 없는 sent 행이 되고, 피드 쿼리(opened 필터만 봄)에
            # stop 한 카드가 재등장한다. 정상 경로의 claimed 행은 항상 pending 이라 영향 없음.
            await session.execute(
                text(
                    f"UPDATE notification_outbox SET status=:s, skip_reason=:r, last_error=:e, "
                    f"locked_until=NULL{sent_clause}, updated_at=now() "
                    f"WHERE id=:id AND status='pending'"
                ).bindparams(
                    bindparam("s", status),
                    bindparam("r", skip_reason),
                    bindparam("e", last_error[:1024] if last_error else None),
                    bindparam("id", outbox_id),
                )
            )
            await session.commit()

    async def _defer_transient(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        outbox_id: int,
        retry_at: datetime,
        error: str | None,
    ) -> None:
        async with session_factory() as session:
            # status='pending' 유지 — fire_at 은 그대로지만 locked_until 로 backoff 동안 재claim 차단.
            await session.execute(
                text(
                    "UPDATE notification_outbox SET locked_until=:lu, next_retry_at=:r, last_error=:e, "
                    "updated_at=now() WHERE id=:id"
                ).bindparams(
                    bindparam("lu", retry_at),
                    bindparam("r", retry_at),
                    bindparam("e", (error or "")[:1024]),
                    bindparam("id", outbox_id),
                )
            )
            await session.commit()


class ClaimedNotification:
    __slots__ = (
        "id",
        "event_id",
        "owner_id",
        "kind",
        "title",
        "body",
        "source_item_id",
        "source_intent_id",
        "collapse_id",
        "attempts",
    )

    def __init__(
        self,
        *,
        id: int,
        event_id: UUID,
        owner_id: UUID,
        kind: str,
        title: str,
        body: str,
        source_item_id: UUID | None,
        source_intent_id: UUID | None,
        collapse_id: str | None,
        attempts: int,
    ) -> None:
        self.id = id
        self.event_id = event_id
        self.owner_id = owner_id
        self.kind = kind
        self.title = title
        self.body = body
        self.source_item_id = source_item_id
        self.source_intent_id = source_intent_id
        self.collapse_id = collapse_id
        self.attempts = attempts


def _render_content(stage: Stage, instance: IntentInstance) -> tuple[str, str]:
    """content_template 을 근거 명사(payload)로 렌더 — generic/단정 금지 톤(notification-agent.md §3).

    슬롯 {title} 만 채운다(라벨/제목). 알 수 없는 슬롯은 빈 문자열로(KeyError 로 죽지 않게). title 은
    OS 알림 제목, 렌더된 template 은 body. template 이 비면 라벨/제목을 body 로 폴백.
    """
    name = instance.payload.title or instance.label or "기록"
    try:
        body = stage.content_template.format(title=name)
    except (KeyError, IndexError, ValueError):
        # LLM 이 지원 안 하는 슬롯을 넣었을 때 — 안전 폴백(빈 슬롯 제거 시도 대신 라벨만).
        body = name
    body = body.strip() or name
    return name, body
