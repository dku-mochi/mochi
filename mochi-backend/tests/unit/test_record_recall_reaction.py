"""RecordRecallReaction 단위테스트 (P5) — 멱등·owner 가드·stop plan cancel·spaced 소생·격리.

DB 통합 fixture 없이 repository 스텁으로 application 레이어의 분기·멱등·소생 매핑만 본다.
`(event_id, owner_id)` + `status='sent'` atomic UPDATE 의 실제 SQL 가드는
PostgresRecallReactionRepository 코드 리뷰가 담당(test_update_instance_lifecycle 와 동일 컨벤션).
"""

from contextlib import nullcontext
from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
)
from app.modules.notifications.application.record_recall_reaction import (
    RecordRecallReaction,
    RecordRecallReactionCommand,
)
from app.modules.notifications.domain.recall_reaction import (
    ReactionKind,
    SentRecallEvent,
)
from app.shared.intent import Intent

_OWNER = uuid4()


class _ReactionRepo:
    """find_sent_event + mark_opened/mark_dismissed(rowcount 제어) + cancel_plan 스텁."""

    def __init__(
        self,
        *,
        event: SentRecallEvent | None,
        opened_rowcount: int = 1,
        dismissed_rowcount: int = 1,
    ) -> None:
        self._event = event
        self._opened_rowcount = opened_rowcount
        self._dismissed_rowcount = dismissed_rowcount
        self.opened_calls = 0
        self.dismissed_calls = 0
        self.cancelled: list[tuple] = []  # (plan_id, owner_id)

    async def find_sent_event(self, *, event_id, owner_id):  # type: ignore[no-untyped-def]
        if self._event is None or self._event.event_id != event_id:
            return None
        return self._event

    async def mark_opened(self, *, event_id, owner_id) -> int:  # type: ignore[no-untyped-def]
        self.opened_calls += 1
        return self._opened_rowcount

    async def mark_dismissed(self, *, event_id, owner_id) -> int:  # type: ignore[no-untyped-def]
        self.dismissed_calls += 1
        return self._dismissed_rowcount

    async def cancel_plan(self, *, plan_id, owner_id) -> None:  # type: ignore[no-untyped-def]
        self.cancelled.append((plan_id, owner_id))

    def savepoint(self):  # type: ignore[no-untyped-def]
        # no-op CM — nullcontext 는 async with 도 지원(Py3.10+). 진짜 savepoint 롤백 격리는
        # 실세션 통합 테스트가 증명(아래 test_revive_savepoint_*). 단위는 호출/회귀만 보장.
        self.savepoint_calls = getattr(self, "savepoint_calls", 0) + 1
        return nullcontext()


class _MochiRepo:
    """find_by_id + update_instance_lifecycle 만 구현하는 스텁(test_update_instance_lifecycle 패턴)."""

    def __init__(self, item: MochiItem | None) -> None:
        self._item = item
        self.lifecycle_updates: list[tuple] = []

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        if self._item is None or self._item.id != mochi_item_id:
            return None
        return self._item

    async def update_instance_lifecycle(  # type: ignore[no-untyped-def]
        self, *, owner_id, mochi_item_id, instance_id, lifecycle
    ):
        if self._item is None:
            return False
        for inst in self._item.intent_instances:
            if inst.id == instance_id:
                inst.lifecycle = lifecycle
                self.lifecycle_updates.append((instance_id, lifecycle.kind))
                return True
        return False


class _FailingMochiRepo:
    """find_by_id 가 항상 예외 — 소생 격리(opened 는 기록되어야) 검증용."""

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        raise RuntimeError("db down")

    async def update_instance_lifecycle(self, **_):  # type: ignore[no-untyped-def]
        raise RuntimeError("unreachable")


def _item(instance: IntentInstance) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(
            channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)
        ),
        intent_instances=(instance,),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


def _event(
    *,
    kind: str = "deadline",
    plan_id=None,
    source_item_id=None,
    source_intent_id=None,
) -> SentRecallEvent:
    return SentRecallEvent(
        event_id=uuid4(),
        kind=kind,
        plan_id=plan_id,
        source_item_id=source_item_id,
        source_intent_id=source_intent_id,
    )


def _cmd(event: SentRecallEvent, reaction: ReactionKind) -> RecordRecallReactionCommand:
    return RecordRecallReactionCommand(
        owner_id=_OWNER, event_id=event.event_id, reaction=reaction
    )


async def _run(reactions: _ReactionRepo, mochi: object, cmd: RecordRecallReactionCommand) -> None:
    await RecordRecallReaction(reactions=reactions, mochi_items=mochi).execute(cmd)  # type: ignore[arg-type]


# ---------- owner + status='sent' 가드 (404) ----------


async def test_unknown_event_raises_not_found() -> None:
    # find_sent_event 가 None — 남의 event_id·pending·이미 종료(sent 아님) → 404.
    repo = _ReactionRepo(event=None)
    ev = _event()
    with pytest.raises(NotFoundError):
        await _run(repo, _MochiRepo(None), _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 0  # 가드 통과 못 함 → UPDATE 미시도


# ---------- opened first-write-wins ----------


async def test_opened_first_write_marks() -> None:
    ev = _event(kind="deadline")
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    await _run(repo, _MochiRepo(None), _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 1


async def test_opened_duplicate_tap_is_idempotent_noop() -> None:
    # 이미 opened(rowcount=0) — 멱등 no-op(예외 없음, 소생 재시도 안 함).
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
    )
    item = _item(inst)
    ev = _event(kind="spaced", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=0)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 1
    # rowcount=0 → 소생 트리거 안 함(중복 탭이 다시 소생시키지 않음).
    assert mochi.lifecycle_updates == []
    assert inst.lifecycle.kind is InstanceLifecycleKind.DECAYING


# ---------- dismissed (soft, 멱등) ----------


async def test_dismissed_marks() -> None:
    ev = _event(kind="spaced")
    repo = _ReactionRepo(event=ev, dismissed_rowcount=1)
    await _run(repo, _MochiRepo(None), _cmd(ev, ReactionKind.DISMISSED))
    assert repo.dismissed_calls == 1
    assert repo.cancelled == []  # dismissed 는 plan 취소 안 함


# ---------- stop → plan cancelled ----------


async def test_stop_cancels_plan() -> None:
    plan_id = uuid4()
    ev = _event(kind="spaced", plan_id=plan_id)
    repo = _ReactionRepo(event=ev)
    await _run(repo, _MochiRepo(None), _cmd(ev, ReactionKind.STOP))
    assert repo.dismissed_calls == 1
    assert repo.cancelled == [(plan_id, _OWNER)]


async def test_stop_without_plan_skips_cancel() -> None:
    # 트랙 C 직행(plan_id NULL) — plan 변경 생략, dismissed 만.
    ev = _event(kind="recall", plan_id=None)
    repo = _ReactionRepo(event=ev)
    await _run(repo, _MochiRepo(None), _cmd(ev, ReactionKind.STOP))
    assert repo.dismissed_calls == 1
    assert repo.cancelled == []


# ---------- opened + spaced + knowledge 소생 ----------


@pytest.mark.parametrize(
    "frm",
    [InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.REVIEW_REQUESTED],
)
async def test_opened_spaced_revives_knowledge(frm: InstanceLifecycleKind) -> None:
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=frm),
    )
    item = _item(inst)
    ev = _event(kind="spaced", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert inst.lifecycle.kind is InstanceLifecycleKind.ACTIVE
    assert mochi.lifecycle_updates == [(inst.id, InstanceLifecycleKind.ACTIVE)]


async def test_opened_spaced_active_is_noop() -> None:
    # active knowledge — 소생 불필요(no-op). opened 는 기록.
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE),
    )
    item = _item(inst)
    ev = _event(kind="spaced", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 1
    assert mochi.lifecycle_updates == []
    assert inst.lifecycle.kind is InstanceLifecycleKind.ACTIVE


async def test_opened_spaced_non_knowledge_is_noop() -> None:
    # spaced 인데 source 가 todo(이론상 드묾) — 비-knowledge 면 소생 안 함.
    inst = IntentInstance(intent_type=Intent.TODO)
    item = _item(inst)
    ev = _event(kind="spaced", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert mochi.lifecycle_updates == []


async def test_opened_non_spaced_kind_skips_revival() -> None:
    # deadline opened — 소생 경로 진입 안 함(spaced 아님).
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
    )
    item = _item(inst)
    ev = _event(kind="deadline", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert mochi.lifecycle_updates == []
    assert inst.lifecycle.kind is InstanceLifecycleKind.DECAYING


# ---------- 소생 격리 (실패해도 opened 기록) ----------


async def test_revival_failure_does_not_break_opened() -> None:
    # 소생 중 예외(db down) — opened_at 기록(mark_opened 호출)은 보존, 예외 전파 안 함.
    ev = _event(kind="spaced", source_item_id=uuid4(), source_intent_id=uuid4())
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    await _run(repo, _FailingMochiRepo(), _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 1  # 반응은 기록됨(예외 격리)


async def test_revive_wraps_lifecycle_write_in_savepoint() -> None:
    # P1#4: spaced 소생의 lifecycle write 는 savepoint(begin_nested) 안에서 실행돼야 outer
    # opened_at 이 aborted-tx 로 롤백되지 않는다. 실세션 격리 증거는 통합 검증(verify_recall_p1.py);
    # 단위는 소생 경로가 savepoint() 를 실제로 연다는 것만 보장.
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
    )
    item = _item(inst)
    ev = _event(kind="spaced", source_item_id=item.id, source_intent_id=inst.id)
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(item)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert getattr(repo, "savepoint_calls", 0) == 1  # 소생 write 가 savepoint 로 감싸졌다
    assert inst.lifecycle.kind is InstanceLifecycleKind.ACTIVE


async def test_opened_spaced_missing_item_is_noop() -> None:
    # source_item_id 가 가리키는 item 이 없음(삭제됨) — 소생 no-op, opened 기록.
    ev = _event(kind="spaced", source_item_id=uuid4(), source_intent_id=uuid4())
    repo = _ReactionRepo(event=ev, opened_rowcount=1)
    mochi = _MochiRepo(None)
    await _run(repo, mochi, _cmd(ev, ReactionKind.OPENED))
    assert repo.opened_calls == 1
    assert mochi.lifecycle_updates == []
