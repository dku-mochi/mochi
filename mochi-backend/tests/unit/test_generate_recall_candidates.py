"""GenerateRecallCandidates 단위테스트 (P7~P9 + 2026-06-17 LLM 게이트) — 필터·게이트·백스톱·fire_at.

DB 없이 repo/gate 스텁으로 use case 의 결정 로직만 본다. ANN cosine SQL·outbox INSERT·advisory lock 의
실제 동작은 PostgresRecallCandidateRepository 코드 리뷰가 담당. fire_at 야간/cap shift 는 순수
가드(test_recall_guards)가 검증 — 여기선 합성 결과만 확인. 결정적 백스톱(폴백 경로 gate_enabled=False)과
LLM 게이트 경로(gate_enabled=True + 스텁) 양쪽을 본다.
"""

from datetime import UTC, datetime
from uuid import uuid4

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
    IntentPayload,
)
from app.modules.notifications.application.generate_recall_candidates import (
    GenerateRecallCandidates,
)
from app.modules.notifications.application.recall_occurrence import KST
from app.modules.notifications.domain.recall_candidate import RecallCandidate
from app.modules.notifications.domain.recall_gate import RecallGateDecision
from app.shared.intent import Intent

_OWNER = uuid4()


def _item(*, title: str | None = "무선 마우스", summary: str | None = "저소음 비교") -> MochiItem:
    payload = IntentPayload(title=title) if title is not None else IntentPayload()
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SAFARI, captured_at=datetime(2026, 5, 1, tzinfo=UTC)),
        intent_instances=(
            IntentInstance(
                intent_type=Intent.KNOWLEDGE,
                payload=payload,
                lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE),
            ),
        ),
        summary=summary,
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
        created_at=datetime(2026, 6, 10, tzinfo=UTC),
    )


def _accept(chosen_index: int = 0, message: str = "지난번 '지난 마우스' 어떠세요?") -> RecallGateDecision:
    return RecallGateDecision(
        recall=True,
        chosen_index=chosen_index,
        relation="comparison",
        confidence=0.8,
        message=message,
        reason="same choice",
    )


_DECLINE = RecallGateDecision(
    recall=False, chosen_index=None, relation="none", confidence=0.0, message="", reason="weak"
)


class _FakeGate:
    def __init__(self, decision: RecallGateDecision | None = None, *, raises: bool = False) -> None:
        self._decision = decision or _DECLINE
        self._raises = raises
        self.calls = 0

    async def decide(self, *, gate_input):  # type: ignore[no-untyped-def]
        self.calls += 1
        if self._raises:
            raise RuntimeError("gate boom")
        return self._decision


class _CandRepo:
    def __init__(
        self,
        *,
        similar: list[RecallCandidate] | None = None,
        recent_recall: bool = False,
        last_dismissed: datetime | None = None,
        same_day: int = 0,
        has_deadline: bool = False,
        owner_recent: bool = False,
    ) -> None:
        self._similar = similar or []
        self._recent_recall = recent_recall
        self._last_dismissed = last_dismissed
        self._same_day = same_day
        self._has_deadline = has_deadline
        self._owner_recent = owner_recent
        self.inserted: list[dict] = []  # type: ignore[type-arg]
        self.locked = 0

    async def acquire_owner_lock(self, *, owner_id):  # type: ignore[no-untyped-def]
        self.locked += 1

    async def recent_owner_recall_exists(self, *, owner_id, since):  # type: ignore[no-untyped-def]
        return self._owner_recent

    async def find_similar(self, *, owner_id, source_item_id, min_score, limit):  # type: ignore[no-untyped-def]
        return self._similar[:limit]

    async def recent_recall_exists(self, *, owner_id, source_item_id, since):  # type: ignore[no-untyped-def]
        return self._recent_recall

    async def last_dismissed_for_intent(self, *, owner_id, source_intent_id):  # type: ignore[no-untyped-def]
        return self._last_dismissed

    async def same_day_count(self, *, owner_id, kst_date):  # type: ignore[no-untyped-def]
        return self._same_day

    async def has_deadline_push_same_day(self, *, owner_id, kst_date):  # type: ignore[no-untyped-def]
        return self._has_deadline

    async def insert_recall(self, **kwargs):  # type: ignore[no-untyped-def]
        self.inserted.append(kwargs)
        return uuid4()


class _MochiRepo:
    def __init__(self, items: dict) -> None:  # type: ignore[type-arg]
        self._items = items

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        return self._items.get(mochi_item_id)


def _use_case(
    *,
    cand: _CandRepo,
    mochi: _MochiRepo,
    gate: _FakeGate | None = None,
    gate_enabled: bool = False,
    gate_dry_run: bool = False,
    owner_cooldown_hours: int = 6,
    near_dup_score: float = 0.92,
) -> GenerateRecallCandidates:
    return GenerateRecallCandidates(
        candidates=cand,
        mochi_items=mochi,
        gate=gate or _FakeGate(),
        min_score=0.6,
        overfetch_limit=40,
        gate_topn=10,
        near_dup_score=near_dup_score,
        gate_enabled=gate_enabled,
        gate_dry_run=gate_dry_run,
        dedup_cooldown_days=7,
        dismiss_cooldown_days=7,
        owner_cooldown_hours=owner_cooldown_hours,
        expires_days=14,
    )


def _similar(
    anchor: MochiItem, *, score: float = 0.82, summary: str | None = "저소음 비교"
) -> RecallCandidate:
    return RecallCandidate(item_id=anchor.id, score=score, summary=summary, category=None, channel=None)


# ── 결정적 폴백 경로 (gate_enabled=False) ──────────────────────────────


async def test_creates_recall_when_candidate_found() -> None:
    source = _item(title="새 마우스")
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is True
    assert len(cand.inserted) == 1
    assert cand.inserted[0]["source_item_id"] == anchor.id
    assert "지난 마우스" in cand.inserted[0]["body"]
    assert cand.locked == 1  # advisory lock 호출됨


async def test_no_similar_skips() -> None:
    source = _item()
    cand = _CandRepo(similar=[])
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is False
    assert cand.inserted == []


async def test_missing_source_skips() -> None:
    cand = _CandRepo(similar=[])
    created = await _use_case(cand=cand, mochi=_MochiRepo({})).run(owner_id=_OWNER, mochi_item_id=uuid4())
    assert created is False
    assert cand.inserted == []


async def test_recent_recall_dedup_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], recent_recall=True)
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is False
    assert cand.inserted == []


async def test_dismiss_cooldown_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], last_dismissed=datetime.now(UTC))
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is False
    assert cand.inserted == []


async def test_track_b_yield_pushes_fire_at_to_later_day() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], has_deadline=True)
    before = datetime.now(UTC)
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is True
    fire_at: datetime = cand.inserted[0]["fire_at"]
    assert fire_at.astimezone(KST).date() > before.astimezone(KST).date()


# ── 백스톱: owner 쿨다운·근중복 필터 ──────────────────────────────────


async def test_owner_cooldown_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], owner_recent=True)
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is False
    assert cand.inserted == []


async def test_near_dup_filtered_out() -> None:
    # 재저장 수준(cos≥0.92)은 앵커 후보에서 제외 → 후보 없음 → 발송 안 함.
    source = _item()
    anchor = _item(title="거의 동일")
    cand = _CandRepo(similar=[_similar(anchor, score=0.97)])
    created = await _use_case(cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})).run(
        owner_id=_OWNER, mochi_item_id=source.id
    )
    assert created is False
    assert cand.inserted == []


# ── LLM 게이트 경로 (gate_enabled=True) ──────────────────────────────


async def test_gate_accept_creates_with_llm_body() -> None:
    source = _item(title="새 마우스")
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    gate = _FakeGate(_accept(message="지난번 '지난 마우스' 어떠세요?"))
    created = await _use_case(
        cand=cand,
        mochi=_MochiRepo({source.id: source, anchor.id: anchor}),
        gate=gate,
        gate_enabled=True,
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is True
    assert gate.calls == 1
    assert cand.inserted[0]["body"] == "지난번 '지난 마우스' 어떠세요?"
    assert cand.inserted[0]["source_item_id"] == anchor.id


async def test_gate_reject_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    gate = _FakeGate(_DECLINE)
    created = await _use_case(
        cand=cand,
        mochi=_MochiRepo({source.id: source, anchor.id: anchor}),
        gate=gate,
        gate_enabled=True,
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []
    assert gate.calls == 1


async def test_gate_exception_skips() -> None:
    # LLM 실패는 best-effort — 발송 안 하고 죽지 않는다.
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    created = await _use_case(
        cand=cand,
        mochi=_MochiRepo({source.id: source, anchor.id: anchor}),
        gate=_FakeGate(raises=True),
        gate_enabled=True,
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []


async def test_gate_dry_run_logs_but_no_insert() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    created = await _use_case(
        cand=cand,
        mochi=_MochiRepo({source.id: source, anchor.id: anchor}),
        gate=_FakeGate(_accept()),
        gate_enabled=True,
        gate_dry_run=True,
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []
