from app.modules.captures.domain.entities import (
    ArchiveReason,
    LifecycleState,
    LifecycleStateKind,
)
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.shared.intent import Intent


def _state(kind: LifecycleStateKind) -> LifecycleState:
    return LifecycleState(kind=kind)


def _archived(reason: ArchiveReason) -> LifecycleState:
    return LifecycleState(kind=LifecycleStateKind.ARCHIVED, archive_reason=reason)


def test_schedule_can_archive_after_active() -> None:
    assert is_allowed(Intent.SCHEDULE, _state(LifecycleStateKind.ACTIVE), _archived(ArchiveReason.SCHEDULE_ENDED))


def test_schedule_can_user_manual_archive() -> None:
    assert is_allowed(Intent.SCHEDULE, _state(LifecycleStateKind.ACTIVE), _archived(ArchiveReason.USER_MANUAL))


def test_schedule_archive_with_wrong_reason_rejected() -> None:
    assert not is_allowed(Intent.SCHEDULE, _state(LifecycleStateKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))


def test_todo_archive_requires_todo_or_user_reason() -> None:
    assert is_allowed(Intent.TODO, _state(LifecycleStateKind.ACTIVE), _archived(ArchiveReason.TODO_COMPLETED))
    assert not is_allowed(Intent.TODO, _state(LifecycleStateKind.ACTIVE), _archived(ArchiveReason.KNOWLEDGE_STALE))


def test_archive_without_reason_rejected() -> None:
    assert not is_allowed(
        Intent.MEMO,
        _state(LifecycleStateKind.ACTIVE),
        LifecycleState(kind=LifecycleStateKind.ARCHIVED, archive_reason=None),
    )


def test_knowledge_can_decay_then_review_requested() -> None:
    assert is_allowed(Intent.KNOWLEDGE, _state(LifecycleStateKind.ACTIVE), _state(LifecycleStateKind.DECAYING))
    assert is_allowed(Intent.KNOWLEDGE, _state(LifecycleStateKind.DECAYING), _state(LifecycleStateKind.REVIEW_REQUESTED))


def test_memo_cannot_enter_review_requested() -> None:
    assert not is_allowed(Intent.MEMO, _state(LifecycleStateKind.ACTIVE), _state(LifecycleStateKind.REVIEW_REQUESTED))
