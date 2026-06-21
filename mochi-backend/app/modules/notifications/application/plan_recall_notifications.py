"""능동 회수 알림 플래너(P2) 유스케이스 — eligibility 게이트 + LLM 설계 + 검증 + 영속.

정본 `journal/proactive-recall/notification-agent.md` §1·§2 / `schema.md` §1·§4.

분석 done 후 worker 가 best-effort 로 호출한다. 분석을 롤백하지 않고, 실패해도 worker 루프를
죽이지 않는다(호출부가 예외 격리). 여기서는 후보 분류 + LLM 호출 + stages 검증 + 1 row 영속만 한다.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.exc import IntegrityError

from app.core.logging import get_logger
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    IntentInstance,
)
from app.modules.notifications.domain.recall_plan import (
    PlanKind,
    RecallPlanStages,
)
from app.modules.notifications.domain.recall_planning import (
    EligibleCandidate,
    PlanningContext,
    RecallContextProviderPort,
    RecallPlannerPort,
    RecallPlanRepositoryPort,
    ScheduledLookup,
)
from app.shared.intent import Intent

log = get_logger("notifications.recall_planner")


def _is_future(value: str | None, now: datetime) -> bool:
    """ISO date/datetime 문자열이 미래(오늘 포함)인지. 파싱 실패·없음 = 미래 아님(보수적)."""
    if not value:
        return False
    raw = value.strip()
    # 'YYYY-MM-DD' 또는 'YYYY-MM-DDТHH:MM' 류. date-only 는 그날 끝까지 미래로 취급.
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        try:
            d = datetime.strptime(raw[:10], "%Y-%m-%d").date()
        except ValueError:
            return False
        return d >= now.date()
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=now.tzinfo or UTC)
    return parsed >= now


def compute_eligible_candidates(
    *,
    intent_instances: tuple[IntentInstance, ...],
    source_item_id: UUID,
    now: datetime,
) -> list[EligibleCandidate]:
    """결정적 eligibility 게이트 — "알림 가치 있는 신규/변경 intent" 만 통과(notification-agent.md §1).

    이 게이트가 "needs_notification 판정"을 대신한다 — v21 system prompt / finalizeAnalysis 구조화
    출력(eval-튜닝된 핵심 분석 경로)을 건드리지 않기 위한 결정(부모 Claude). 분석 결과만 읽는다.

    통과:
      - schedule + 미래 date/end_date  → deadline_backoff (anchor=event_date)
      - todo + 미래 deadline           → deadline_backoff (anchor=deadline)
      - todo + 마감없음                → recurring_nudge (실행가능 판단은 LLM 에 위임, 후보로는 올림)
      - knowledge                      → spaced
    제외: memo / 과거 date·deadline / archived instance / intent 없음(여기 list 가 비면 빈 결과).
    """
    candidates: list[EligibleCandidate] = []
    for inst in intent_instances:
        # archived(완료/만료) instance 는 제외 — 분석 직후 instance 는 항상 active 로 태어나지만,
        # 재분석/변경 경로를 통해 archived 가 섞일 수 있어 방어한다.
        if inst.lifecycle.kind is InstanceLifecycleKind.ARCHIVED:
            continue

        p = inst.payload
        if inst.intent_type is Intent.SCHEDULE:
            anchor = (
                p.date if _is_future(p.date, now) else (p.end_date if _is_future(p.end_date, now) else None)
            )
            if anchor is None:
                continue  # 과거/날짜없는 일정은 알림 가치 없음
            candidates.append(
                EligibleCandidate(
                    source_intent_id=inst.id,
                    source_item_id=source_item_id,
                    intent_type=inst.intent_type.value,
                    suggested_plan_kind=PlanKind.DEADLINE_BACKOFF,
                    title=p.title,
                    label=inst.label,
                    anchor_value=anchor,
                )
            )
        elif inst.intent_type is Intent.TODO:
            if _is_future(p.deadline, now):
                kind = PlanKind.DEADLINE_BACKOFF
                anchor = p.deadline
            elif p.deadline:
                continue  # 과거 마감 = 알림 가치 없음
            else:
                kind = PlanKind.RECURRING_NUDGE  # 마감없는 todo — 주기넛지 후보(최종 판단은 LLM)
                anchor = None
            candidates.append(
                EligibleCandidate(
                    source_intent_id=inst.id,
                    source_item_id=source_item_id,
                    intent_type=inst.intent_type.value,
                    suggested_plan_kind=kind,
                    title=p.title,
                    label=inst.label,
                    anchor_value=anchor,
                )
            )
        elif inst.intent_type is Intent.KNOWLEDGE:
            candidates.append(
                EligibleCandidate(
                    source_intent_id=inst.id,
                    source_item_id=source_item_id,
                    intent_type=inst.intent_type.value,
                    suggested_plan_kind=PlanKind.SPACED,
                    title=p.title,
                    label=inst.label,
                    anchor_value=None,
                )
            )
        # memo: 제외(알림 가치 없음).
    return candidates


class PlanRecallNotifications:
    """eligibility → 컨텍스트 → LLM 설계 → stages 검증 → notification_plan 영속."""

    def __init__(
        self,
        *,
        planner: RecallPlannerPort,
        context_provider: RecallContextProviderPort,
        repository: RecallPlanRepositoryPort,
        scheduled_lookup: ScheduledLookup,
    ) -> None:
        self._planner = planner
        self._context = context_provider
        self._repo = repository
        self._scheduled = scheduled_lookup

    async def run(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        intent_instances: tuple[IntentInstance, ...],
    ) -> int:
        """eligible 건마다 plan 을 설계·영속. 생성된 plan 수를 반환(로깅/테스트용)."""
        now = datetime.now(UTC)
        candidates = compute_eligible_candidates(
            intent_instances=intent_instances, source_item_id=mochi_item_id, now=now
        )
        if not candidates:
            return 0

        # 컨텍스트는 후보 전체에 공유(같은 item 의 최근/유사/과거 알림은 동일).
        context = await self._context.gather(owner_id=owner_id, mochi_item_id=mochi_item_id)

        created = 0
        for cand in candidates:
            try:
                if await self._plan_one(owner_id=owner_id, candidate=cand, context=context):
                    created += 1
            except Exception as exc:  # noqa: BLE001
                # 후보 단위 격리 — 한 후보 실패가 다른 후보·worker 를 죽이지 않게(best-effort).
                log.warning(
                    "recall.plan_failed",
                    owner_id=str(owner_id),
                    source_intent_id=str(cand.source_intent_id),
                    exception=str(exc),
                    exc_info=True,
                )
        return created

    async def _plan_one(
        self,
        *,
        owner_id: UUID,
        candidate: EligibleCandidate,
        context: PlanningContext,
    ) -> bool:
        # plan 폭증 방지(codex-3): 같은 source_intent 에 이미 active plan 이 있으면 supersede 후보다.
        existing = await self._repo.find_active_by_intent(
            owner_id=owner_id, source_intent_id=candidate.source_intent_id
        )

        decision = await self._planner.plan(
            candidate=candidate, context=context, get_scheduled=self._scheduled
        )
        if decision is None:
            # "애매하면 안 보낸다" — LLM 이 알림 가치 없다고 판단. plan 미생성.
            log.info(
                "recall.plan_skipped",
                owner_id=str(owner_id),
                source_intent_id=str(candidate.source_intent_id),
                reason="planner_declined",
            )
            return False

        # stages 검증(삽입 전) — malformed/adversarial 차단. 실패 시 plan 미생성 + 로깅.
        try:
            validated = RecallPlanStages.model_validate(decision.stages).validate_for(decision.plan_kind)
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "recall.stages_invalid",
                owner_id=str(owner_id),
                source_intent_id=str(candidate.source_intent_id),
                plan_kind=decision.plan_kind.value,
                exception=str(exc),
            )
            return False

        # next_eligible_at: 가장 이른 stage 직전(보수적으로 now). cron 이 이 시각부터 평가한다(P3 계약).
        next_eligible_at = datetime.now(UTC)
        try:
            new_plan_id = await self._repo.insert_plan(
                owner_id=owner_id,
                source_intent_id=candidate.source_intent_id,
                source_item_id=candidate.source_item_id,
                plan_kind=decision.plan_kind,
                stages=validated.model_dump(mode="json"),
                generated_model=decision.generated_model[:64],  # String(64) 컬럼 — 안전 truncate
                next_eligible_at=next_eligible_at,
            )
        except IntegrityError:
            # 같은 (owner, source_intent) active plan 부분 UNIQUE 충돌(H-3): 동시 워커가 먼저 생성했다.
            # insert 는 savepoint 안에서 돌아 이 한 건만 롤백되고 세션은 살아 있다(best-effort skip,
            # 크래시·루프 금지). 전체 플래닝이 best-effort 라 skip 이 안전하다.
            log.info(
                "recall.plan_skipped",
                owner_id=str(owner_id),
                source_intent_id=str(candidate.source_intent_id),
                reason="concurrent_active_plan",
            )
            return False

        # supersede: 같은 source_intent 의 기존 active plan 을 같은 흐름에서 교체(schema.md §4-2).
        # planner 가 명시 supersede_plan_id 를 줬으면 그것을, 아니면 게이트가 찾은 existing 을 교체한다.
        supersede_id = decision.supersede_plan_id or (existing.id if existing else None)
        if supersede_id is not None and supersede_id != new_plan_id:
            await self._repo.supersede(owner_id=owner_id, old_plan_id=supersede_id, new_plan_id=new_plan_id)
            log.info(
                "recall.plan_superseded",
                owner_id=str(owner_id),
                old_plan_id=str(supersede_id),
                new_plan_id=str(new_plan_id),
            )

        log.info(
            "recall.plan_created",
            owner_id=str(owner_id),
            source_intent_id=str(candidate.source_intent_id),
            plan_id=str(new_plan_id),
            plan_kind=decision.plan_kind.value,
            stage_count=len(validated.stages),
        )
        return True
