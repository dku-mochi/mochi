"""능동 회수 알림 — eligibility 게이트 단위테스트 (P2).

결정적 게이트(compute_eligible_candidates)가 분석결과 intent_instances 를 올바로 분류하는지.
schedule(미래/과거) / todo(마감有/無/과거) / knowledge / memo / intent없음 / archived.
"""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
    IntentPayload,
)
from app.modules.notifications.application.plan_recall_notifications import (
    compute_eligible_candidates,
)
from app.modules.notifications.domain.recall_plan import PlanKind
from app.shared.intent import Intent

_NOW = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)
_FUTURE = (_NOW + timedelta(days=10)).date().isoformat()
_PAST = (_NOW - timedelta(days=10)).date().isoformat()


def _inst(intent: Intent, payload: IntentPayload, *, archived: bool = False) -> IntentInstance:
    lifecycle = (
        InstanceLifecycleState(kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.USER_MANUAL)
        if archived
        else InstanceLifecycleState()
    )
    return IntentInstance(intent_type=intent, payload=payload, lifecycle=lifecycle)


def _classify(*insts: IntentInstance):
    return compute_eligible_candidates(
        intent_instances=tuple(insts), source_item_id=uuid4(), now=_NOW
    )


def test_future_schedule_is_deadline_backoff():
    out = _classify(_inst(Intent.SCHEDULE, IntentPayload(title="토익 시험", date=_FUTURE)))
    assert len(out) == 1
    assert out[0].suggested_plan_kind is PlanKind.DEADLINE_BACKOFF
    assert out[0].intent_type == "schedule"
    assert out[0].anchor_value == _FUTURE


def test_past_schedule_excluded():
    assert _classify(_inst(Intent.SCHEDULE, IntentPayload(title="지난 회의", date=_PAST))) == []


def test_schedule_without_date_excluded():
    assert _classify(_inst(Intent.SCHEDULE, IntentPayload(title="날짜 없는 일정"))) == []


def test_schedule_uses_end_date_when_only_end_is_future():
    # date 가 과거고 end_date 만 미래면 end_date 를 anchor 로(기간형 일정 끝까지 알림 가치).
    out = _classify(
        _inst(Intent.SCHEDULE, IntentPayload(title="페스티벌", date=_PAST, end_date=_FUTURE))
    )
    assert len(out) == 1
    assert out[0].anchor_value == _FUTURE


def test_todo_with_future_deadline_is_deadline_backoff():
    out = _classify(_inst(Intent.TODO, IntentPayload(title="과제 제출", deadline=_FUTURE)))
    assert len(out) == 1
    assert out[0].suggested_plan_kind is PlanKind.DEADLINE_BACKOFF
    assert out[0].anchor_value == _FUTURE


def test_todo_without_deadline_is_recurring_nudge():
    out = _classify(_inst(Intent.TODO, IntentPayload(title="엄마한테 전화")))
    assert len(out) == 1
    assert out[0].suggested_plan_kind is PlanKind.RECURRING_NUDGE
    assert out[0].anchor_value is None


def test_todo_with_past_deadline_excluded():
    assert _classify(_inst(Intent.TODO, IntentPayload(title="지난 마감", deadline=_PAST))) == []


def test_knowledge_is_spaced():
    out = _classify(_inst(Intent.KNOWLEDGE, IntentPayload(title="RAG 자료")))
    assert len(out) == 1
    assert out[0].suggested_plan_kind is PlanKind.SPACED


def test_memo_excluded():
    assert _classify(_inst(Intent.MEMO, IntentPayload(title="그냥 메모"))) == []


def test_no_intents_yields_empty():
    assert compute_eligible_candidates(
        intent_instances=(), source_item_id=uuid4(), now=_NOW
    ) == []


def test_archived_instance_excluded():
    assert _classify(
        _inst(Intent.SCHEDULE, IntentPayload(title="끝난 일정", date=_FUTURE), archived=True)
    ) == []


def test_mixed_intents_classified_independently():
    out = _classify(
        _inst(Intent.SCHEDULE, IntentPayload(title="시험", date=_FUTURE)),
        _inst(Intent.TODO, IntentPayload(title="할일")),
        _inst(Intent.KNOWLEDGE, IntentPayload(title="지식")),
        _inst(Intent.MEMO, IntentPayload(title="메모")),
    )
    kinds = {c.intent_type: c.suggested_plan_kind for c in out}
    assert kinds == {
        "schedule": PlanKind.DEADLINE_BACKOFF,
        "todo": PlanKind.RECURRING_NUDGE,
        "knowledge": PlanKind.SPACED,
    }
