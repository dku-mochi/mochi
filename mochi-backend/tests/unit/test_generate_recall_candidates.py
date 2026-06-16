"""GenerateRecallCandidates 단위테스트 (P7~P9) — 후보 생성·게이트 결정·fire_at 미루기.

DB 없이 repo/gate 스텁으로 use case 의 결정 로직만 본다. ANN cosine SQL·outbox INSERT 의 실제
동작은 PostgresRecallCandidateRepository 코드 리뷰가 담당(test_get_recall_feed 와 동일 컨벤션).
fire_at 의 야간/cap shift 자체는 순수 가드(test_recall_guards)가 검증 — 여기선 합성 결과만 확인.
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
    )


class _CandRepo:
    def __init__(
        self,
        *,
        similar: list[RecallCandidate] | None = None,
        recent_recall: bool = False,
        last_dismissed: datetime | None = None,
        same_day: int = 0,
        has_deadline: bool = False,
    ) -> None:
        self._similar = similar or []
        self._recent_recall = recent_recall
        self._last_dismissed = last_dismissed
        self._same_day = same_day
        self._has_deadline = has_deadline
        self.inserted: list[dict] = []  # type: ignore[type-arg]

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
) -> GenerateRecallCandidates:
    return GenerateRecallCandidates(
        candidates=cand,
        mochi_items=mochi,
        min_score=0.6,
        candidate_limit=10,
        dedup_cooldown_days=7,
        dismiss_cooldown_days=7,
        daily_cap=3,
        quiet_start_hour=21,
        quiet_end_hour=8,
        expires_days=14,
    )


def _similar(anchor: MochiItem, *, summary: str | None = "저소음 비교") -> RecallCandidate:
    return RecallCandidate(item_id=anchor.id, score=0.82, summary=summary, category=None, channel=None)


async def test_creates_recall_when_candidate_found() -> None:
    source = _item(title="새 마우스")
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)])
    created = await _use_case(
        cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is True
    assert len(cand.inserted) == 1
    assert cand.inserted[0]["source_item_id"] == anchor.id
    assert "지난 마우스" in cand.inserted[0]["body"]


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
    created = await _use_case(cand=cand, mochi=_MochiRepo({})).run(
        owner_id=_OWNER, mochi_item_id=uuid4()
    )
    assert created is False
    assert cand.inserted == []


async def test_recent_recall_dedup_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], recent_recall=True)
    created = await _use_case(
        cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []


async def test_dismiss_cooldown_skips() -> None:
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], last_dismissed=datetime.now(UTC))
    created = await _use_case(
        cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []


async def test_generic_copy_skips() -> None:
    # 앵커에 제목도 요약도 없으면 generic copy → 발송 안 함.
    source = _item()
    anchor = _item(title=None, summary=None)
    cand = _CandRepo(similar=[_similar(anchor, summary=None)])
    created = await _use_case(
        cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is False
    assert cand.inserted == []


async def test_track_b_yield_pushes_fire_at_to_later_day() -> None:
    # 같은 날 deadline push 가 있으면 회수 fire_at 을 다음 KST 날짜로 민다(drop 아님).
    source = _item()
    anchor = _item(title="지난 마우스")
    cand = _CandRepo(similar=[_similar(anchor)], has_deadline=True)
    before = datetime.now(UTC)
    created = await _use_case(
        cand=cand, mochi=_MochiRepo({source.id: source, anchor.id: anchor})
    ).run(owner_id=_OWNER, mochi_item_id=source.id)
    assert created is True
    fire_at: datetime = cand.inserted[0]["fire_at"]
    assert fire_at.astimezone(KST).date() > before.astimezone(KST).date()
