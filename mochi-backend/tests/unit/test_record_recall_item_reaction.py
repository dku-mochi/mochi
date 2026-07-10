"""RecordRecallItemReaction 단위테스트 — 피드 반응(item 기준)의 분기·소생·stop·격리.

배경: 피드 카드의 open/stop 이 event 기준이라 event 없음(트랙 A)·pending 404(트랙 C)로 유실
→ 재fetch 마다 카드 부활. 이 유스케이스가 item 기준으로 받는다. DB 통합 fixture 없이 repository
스텁으로 application 분기만 본다(SQL 가드는 PostgresRecallReactionRepository 코드 리뷰 담당 —
test_record_recall_reaction 과 동일 컨벤션).
"""

from contextlib import nullcontext
from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import DomainError, NotFoundError
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
from app.modules.notifications.application.record_recall_item_reaction import (
    RecordRecallItemReaction,
    RecordRecallItemReactionCommand,
)
from app.modules.notifications.domain.recall_reaction import ReactionKind
from app.shared.intent import Intent

_OWNER = uuid4()


class _ReactionRepo:
    """item 기준 메서드(open/stop/plan 목록) + cancel_plan + savepoint 스텁."""

    def __init__(self, *, spaced_plan_ids: list | None = None) -> None:
        self._spaced_plan_ids = spaced_plan_ids or []
        self.opened_items: list[tuple] = []  # (item_id, owner_id) — 트랙 C open 기록
        self.stopped_items: list[tuple] = []  # (item_id, owner_id) — 트랙 C stop 종결
        self.cancelled: list[tuple] = []  # (plan_id, owner_id) — 트랙 A stop
        self.savepoint_calls = 0

    async def open_recall_rows_for_item(self, *, owner_id, item_id) -> int:  # type: ignore[no-untyped-def]
        self.opened_items.append((item_id, owner_id))
        return 1

    async def list_active_spaced_plan_ids(self, *, owner_id, source_item_id):  # type: ignore[no-untyped-def]
        return list(self._spaced_plan_ids)

    async def stop_recall_rows_for_item(self, *, owner_id, item_id) -> int:  # type: ignore[no-untyped-def]
        self.stopped_items.append((item_id, owner_id))
        return 1

    async def cancel_plan(self, *, plan_id, owner_id) -> None:  # type: ignore[no-untyped-def]
        self.cancelled.append((plan_id, owner_id))

    def savepoint(self):  # type: ignore[no-untyped-def]
        self.savepoint_calls += 1
        return nullcontext()


class _MochiRepo:
    """find_by_id + update_instance_lifecycle 스텁(test_record_recall_reaction 패턴)."""

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


def _item(*instances: IntentInstance) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime(2026, 6, 1, tzinfo=UTC)),
        intent_instances=tuple(instances),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


async def _run(reactions: _ReactionRepo, mochi: _MochiRepo, item_id, reaction: ReactionKind) -> None:  # type: ignore[no-untyped-def]
    await RecordRecallItemReaction(reactions=reactions, mochi_items=mochi).execute(  # type: ignore[arg-type]
        RecordRecallItemReactionCommand(owner_id=_OWNER, item_id=item_id, reaction=reaction)
    )


# ---------- 가드 (404 / 400) ----------


async def test_unknown_item_raises_not_found() -> None:
    # 삭제됨·남의 item(owner 스코프 조회) → 404. 트랙 C UPDATE 미시도.
    repo = _ReactionRepo()
    with pytest.raises(NotFoundError):
        await _run(repo, _MochiRepo(None), uuid4(), ReactionKind.OPENED)
    assert repo.opened_items == []


async def test_dismissed_is_unsupported() -> None:
    # 피드 표면엔 soft-dismiss 제스처가 없다 — event 기준 반응만의 의미라 400.
    item = _item(IntentInstance(intent_type=Intent.KNOWLEDGE))
    repo = _ReactionRepo()
    with pytest.raises(DomainError) as exc:
        await _run(repo, _MochiRepo(item), item.id, ReactionKind.DISMISSED)
    assert exc.value.code == "recall_item_reaction.unsupported"


# ---------- opened — 트랙 C 기록 + spaced 소생 ----------


@pytest.mark.parametrize(
    "frm",
    [InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.REVIEW_REQUESTED],
)
async def test_opened_revives_knowledge_and_marks_track_c(frm: InstanceLifecycleKind) -> None:
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=frm),
    )
    item = _item(inst)
    repo = _ReactionRepo()
    mochi = _MochiRepo(item)
    await _run(repo, mochi, item.id, ReactionKind.OPENED)
    assert repo.opened_items == [(item.id, _OWNER)]  # 트랙 C 행 기록/종결
    assert inst.lifecycle.kind is InstanceLifecycleKind.ACTIVE  # 트랙 A 소생
    assert mochi.lifecycle_updates == [(inst.id, InstanceLifecycleKind.ACTIVE)]
    assert repo.savepoint_calls == 1  # 소생 write 는 savepoint 로 격리(P1#4)


async def test_opened_active_knowledge_is_noop_revive() -> None:
    # active — 소생 불필요. 트랙 C 기록은 그래도 수행(멱등 UPDATE).
    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE),
    )
    item = _item(inst)
    repo = _ReactionRepo()
    mochi = _MochiRepo(item)
    await _run(repo, mochi, item.id, ReactionKind.OPENED)
    assert repo.opened_items == [(item.id, _OWNER)]
    assert mochi.lifecycle_updates == []


async def test_opened_non_knowledge_is_noop_revive() -> None:
    # todo/schedule 만 있는 item(트랙 C 앵커가 kind 무관인 경우) — 소생 없음, 트랙 C 기록만.
    inst = IntentInstance(intent_type=Intent.TODO)
    item = _item(inst)
    repo = _ReactionRepo()
    mochi = _MochiRepo(item)
    await _run(repo, mochi, item.id, ReactionKind.OPENED)
    assert repo.opened_items == [(item.id, _OWNER)]
    assert mochi.lifecycle_updates == []


async def test_opened_revives_every_revivable_instance() -> None:
    # knowledge 인스턴스가 여럿(드묾) — decaying/reviewRequested 전부 소생, active 는 건너뜀.
    decaying = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
    )
    review = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.REVIEW_REQUESTED),
    )
    active = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE),
    )
    item = _item(decaying, review, active)
    repo = _ReactionRepo()
    mochi = _MochiRepo(item)
    await _run(repo, mochi, item.id, ReactionKind.OPENED)
    assert {u[0] for u in mochi.lifecycle_updates} == {decaying.id, review.id}
    assert decaying.lifecycle.kind is InstanceLifecycleKind.ACTIVE
    assert review.lifecycle.kind is InstanceLifecycleKind.ACTIVE


async def test_revive_failure_does_not_break_opened() -> None:
    # 소생 중 예외(db down) — 트랙 C opened 기록은 보존, 예외 전파 안 함(격리).
    class _FailingUpdateRepo(_MochiRepo):
        async def update_instance_lifecycle(self, **_):  # type: ignore[no-untyped-def]
            raise RuntimeError("db down")

    inst = IntentInstance(
        intent_type=Intent.KNOWLEDGE,
        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
    )
    item = _item(inst)
    repo = _ReactionRepo()
    await _run(repo, _FailingUpdateRepo(item), item.id, ReactionKind.OPENED)
    assert repo.opened_items == [(item.id, _OWNER)]  # 반응은 기록됨(예외 격리)


# ---------- stop — spaced plan cancel + 트랙 C 종결 ----------


async def test_stop_cancels_spaced_plans_and_recall_rows() -> None:
    plan_a, plan_b = uuid4(), uuid4()
    item = _item(IntentInstance(intent_type=Intent.KNOWLEDGE))
    repo = _ReactionRepo(spaced_plan_ids=[plan_a, plan_b])
    mochi = _MochiRepo(item)
    await _run(repo, mochi, item.id, ReactionKind.STOP)
    assert repo.cancelled == [(plan_a, _OWNER), (plan_b, _OWNER)]  # 트랙 A 전부 영구 취소
    assert repo.stopped_items == [(item.id, _OWNER)]  # 트랙 C 행 종결
    assert mochi.lifecycle_updates == []  # stop 은 소생 안 함


async def test_stop_without_plans_still_stops_recall_rows() -> None:
    # 트랙 C 만 있는 item(plan 없음) — plan cancel 생략, 행 종결은 수행.
    item = _item(IntentInstance(intent_type=Intent.TODO))
    repo = _ReactionRepo(spaced_plan_ids=[])
    await _run(repo, _MochiRepo(item), item.id, ReactionKind.STOP)
    assert repo.cancelled == []
    assert repo.stopped_items == [(item.id, _OWNER)]
