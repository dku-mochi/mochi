"""intent **instance** 차등 생명주기 정책 검증 (2026-06-04 빅뱅 — instance 단위).

is_allowed 는 instance 의 ``intent_type`` 으로 (kind 전이) + (archive reason 적합성)을 본다.
item 처리상태(ingested/analyzing/analyzed/failed)와는 직교한다.
"""

from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
)
from app.shared.intent import Intent


def _state(kind: InstanceLifecycleKind) -> InstanceLifecycleState:
    return InstanceLifecycleState(kind=kind)


def _archived(reason: ArchiveReason) -> InstanceLifecycleState:
    return InstanceLifecycleState(kind=InstanceLifecycleKind.ARCHIVED, archive_reason=reason)


def test_schedule_can_archive_after_active() -> None:
    assert is_allowed(Intent.SCHEDULE, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.SCHEDULE_ENDED))


def test_schedule_can_user_manual_archive() -> None:
    assert is_allowed(Intent.SCHEDULE, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.USER_MANUAL))


def test_schedule_archive_with_wrong_reason_rejected() -> None:
    assert not is_allowed(Intent.SCHEDULE, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))


def test_todo_archive_requires_todo_or_user_reason() -> None:
    assert is_allowed(Intent.TODO, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))
    assert not is_allowed(Intent.TODO, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.KNOWLEDGE_STALE))


def test_archive_without_reason_rejected() -> None:
    assert not is_allowed(
        Intent.MEMO,
        _state(InstanceLifecycleKind.ACTIVE),
        InstanceLifecycleState(kind=InstanceLifecycleKind.ARCHIVED, archive_reason=None),
    )


def test_knowledge_can_decay_then_review_requested() -> None:
    assert is_allowed(Intent.KNOWLEDGE, _state(InstanceLifecycleKind.ACTIVE), _state(InstanceLifecycleKind.DECAYING))
    assert is_allowed(
        Intent.KNOWLEDGE, _state(InstanceLifecycleKind.DECAYING), _state(InstanceLifecycleKind.REVIEW_REQUESTED)
    )


def test_memo_cannot_enter_review_requested() -> None:
    assert not is_allowed(
        Intent.MEMO, _state(InstanceLifecycleKind.ACTIVE), _state(InstanceLifecycleKind.REVIEW_REQUESTED)
    )


def test_instance_transition_is_isolated_by_type() -> None:
    """instance 전이는 그 instance 의 type 으로만 검증 — 한 캡쳐의 다른 instance 와 독립(검증기준 1).

    같은 캡쳐에서 todo 를 완료(todoCompleted)해도, schedule instance 는 todoCompleted 로 archive 불가.
    """
    assert is_allowed(Intent.TODO, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))
    assert not is_allowed(Intent.SCHEDULE, _state(InstanceLifecycleKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))
