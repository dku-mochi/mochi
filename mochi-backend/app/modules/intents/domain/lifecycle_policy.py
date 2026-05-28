"""4-Intent 차등 생명주기 정책. iOS `CoreDomain.LifecyclePolicy` 와 1:1 매칭.

`is_allowed` 는 (kind 전이) + (archive reason 의 Intent 적합성) 둘 다 검증한다.
"""

from app.modules.captures.domain.entities import (
    ArchiveReason,
    LifecycleState,
    LifecycleStateKind,
)
from app.shared.intent import Intent


class LifecycleTransitionError(Exception):
    def __init__(self, intent: Intent, frm: LifecycleState, to: LifecycleState):
        super().__init__(f"Illegal transition for {intent}: {frm.kind} → {to.kind}")
        self.intent = intent
        self.frm = frm
        self.to = to


_ALLOWED_KIND_PAIRS: dict[Intent, set[tuple[LifecycleStateKind, LifecycleStateKind]]] = {
    Intent.SCHEDULE: {
        (LifecycleStateKind.INGESTED, LifecycleStateKind.ANALYZING),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.FAILED),
        (LifecycleStateKind.ACTIVE, LifecycleStateKind.ARCHIVED),
    },
    Intent.TODO: {
        (LifecycleStateKind.INGESTED, LifecycleStateKind.ANALYZING),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.FAILED),
        (LifecycleStateKind.ACTIVE, LifecycleStateKind.ARCHIVED),
    },
    Intent.KNOWLEDGE: {
        (LifecycleStateKind.INGESTED, LifecycleStateKind.ANALYZING),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.FAILED),
        (LifecycleStateKind.ACTIVE, LifecycleStateKind.DECAYING),
        (LifecycleStateKind.DECAYING, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.DECAYING, LifecycleStateKind.REVIEW_REQUESTED),
        (LifecycleStateKind.REVIEW_REQUESTED, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.REVIEW_REQUESTED, LifecycleStateKind.ARCHIVED),
    },
    Intent.MEMO: {
        (LifecycleStateKind.INGESTED, LifecycleStateKind.ANALYZING),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.ACTIVE),
        (LifecycleStateKind.ANALYZING, LifecycleStateKind.FAILED),
        (LifecycleStateKind.ACTIVE, LifecycleStateKind.ARCHIVED),
    },
}

# Intent별 합법적인 archive reason. `USER_MANUAL` 은 모든 Intent에서 허용된다.
_INTENT_ARCHIVE_REASONS: dict[Intent, set[ArchiveReason]] = {
    Intent.SCHEDULE: {ArchiveReason.SCHEDULE_ENDED, ArchiveReason.USER_MANUAL},
    Intent.TODO: {ArchiveReason.TODO_COMPLETED, ArchiveReason.USER_MANUAL},
    Intent.KNOWLEDGE: {ArchiveReason.KNOWLEDGE_STALE, ArchiveReason.USER_MANUAL},
    Intent.MEMO: {ArchiveReason.USER_MANUAL},
}


def is_allowed(intent: Intent, current: LifecycleState, next_state: LifecycleState) -> bool:
    if (current.kind, next_state.kind) not in _ALLOWED_KIND_PAIRS[intent]:
        return False
    if next_state.kind is LifecycleStateKind.ARCHIVED:
        if next_state.archive_reason is None:
            return False
        return next_state.archive_reason in _INTENT_ARCHIVE_REASONS[intent]
    return True


def expected_archive_reason(intent: Intent) -> ArchiveReason:
    return {
        Intent.SCHEDULE: ArchiveReason.SCHEDULE_ENDED,
        Intent.TODO: ArchiveReason.TODO_COMPLETED,
        Intent.KNOWLEDGE: ArchiveReason.KNOWLEDGE_STALE,
        Intent.MEMO: ArchiveReason.USER_MANUAL,
    }[intent]


KNOWLEDGE_ACTIVE_DAYS = 30
KNOWLEDGE_DECAY_DAYS = 180
