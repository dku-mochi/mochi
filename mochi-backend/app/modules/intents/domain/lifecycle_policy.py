"""4-Intent **instance** 차등 생명주기 정책 (2026-06-04 빅뱅 — instance 단위).

intent instance 의 의미 lifecycle(active/decaying/reviewRequested/archived) 전이와
archive_reason 적합성을 검증한다. item 의 처리 파이프라인 상태(ingested/analyzing/analyzed/
failed)와는 **직교**한다 — 그쪽은 단일 선형 전이라 정책이 필요 없다.

instance 는 분석 성공 시점에만 생성되므로 항상 ``active`` 로 태어난다(ingested/analyzing/
failed 진입 없음). iOS ``CoreDomain.LifecyclePolicy`` 와 1:1 매칭.
"""

from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
)
from app.shared.intent import Intent


class InstanceLifecycleTransitionError(Exception):
    def __init__(
        self,
        intent_type: Intent,
        frm: InstanceLifecycleState,
        to: InstanceLifecycleState,
    ):
        super().__init__(f"Illegal instance transition for {intent_type}: {frm.kind} → {to.kind}")
        self.intent_type = intent_type
        self.frm = frm
        self.to = to


# intent_type 별 허용 전이. instance 는 active 에서 출발한다.
_ALLOWED_KIND_PAIRS: dict[Intent, set[tuple[InstanceLifecycleKind, InstanceLifecycleKind]]] = {
    Intent.SCHEDULE: {
        (InstanceLifecycleKind.ACTIVE, InstanceLifecycleKind.ARCHIVED),
    },
    Intent.TODO: {
        (InstanceLifecycleKind.ACTIVE, InstanceLifecycleKind.ARCHIVED),
    },
    Intent.KNOWLEDGE: {
        (InstanceLifecycleKind.ACTIVE, InstanceLifecycleKind.DECAYING),
        (InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.ACTIVE),
        (InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.REVIEW_REQUESTED),
        (InstanceLifecycleKind.REVIEW_REQUESTED, InstanceLifecycleKind.ACTIVE),
        (InstanceLifecycleKind.REVIEW_REQUESTED, InstanceLifecycleKind.ARCHIVED),
    },
    Intent.MEMO: {
        (InstanceLifecycleKind.ACTIVE, InstanceLifecycleKind.ARCHIVED),
    },
}

# intent_type 별 합법적인 archive reason. ``USER_MANUAL`` 은 모든 type 에서 허용된다.
_INTENT_ARCHIVE_REASONS: dict[Intent, set[ArchiveReason]] = {
    Intent.SCHEDULE: {ArchiveReason.SCHEDULE_ENDED, ArchiveReason.USER_MANUAL},
    Intent.TODO: {ArchiveReason.TODO_COMPLETED, ArchiveReason.USER_MANUAL},
    Intent.KNOWLEDGE: {ArchiveReason.KNOWLEDGE_STALE, ArchiveReason.USER_MANUAL},
    Intent.MEMO: {ArchiveReason.USER_MANUAL},
}


def is_allowed(
    intent_type: Intent,
    current: InstanceLifecycleState,
    next_state: InstanceLifecycleState,
) -> bool:
    """instance lifecycle 전이가 합법인가 — (kind 전이) + (archive reason 의 type 적합성)."""
    if (current.kind, next_state.kind) not in _ALLOWED_KIND_PAIRS[intent_type]:
        return False
    if next_state.kind is InstanceLifecycleKind.ARCHIVED:
        if next_state.archive_reason is None:
            return False
        return next_state.archive_reason in _INTENT_ARCHIVE_REASONS[intent_type]
    return True


def expected_archive_reason(intent_type: Intent) -> ArchiveReason:
    return {
        Intent.SCHEDULE: ArchiveReason.SCHEDULE_ENDED,
        Intent.TODO: ArchiveReason.TODO_COMPLETED,
        Intent.KNOWLEDGE: ArchiveReason.KNOWLEDGE_STALE,
        Intent.MEMO: ArchiveReason.USER_MANUAL,
    }[intent_type]


KNOWLEDGE_ACTIVE_DAYS = 30
KNOWLEDGE_DECAY_DAYS = 180
