"""월간 정리(monthly digest) + 다가올 미해결 use case 단위 테스트.

DB fixture 없이 in-memory repo + fake LLM 으로 application 로직만 검증한다:
카테고리 정규화(fine→coarse) write·마킹, 3개 미만 폴백, 매핑 누락 graceful,
known_categories(연쇄 톤앤매너) 전달, 그리고 todo+schedule 임박순 정렬.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from app.modules.mochi_items.application.monthly_digest import (
    STATIC_GREETING,
    GenerateMonthlyDigest,
)
from app.modules.mochi_items.application.queries import ListUpcomingActionables
from app.modules.mochi_items.domain.digest_port import (
    CategoryGroup,
    MonthlyDigestLLMResult,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import IntentInstance, IntentPayload
from app.shared.intent import Intent

_OWNER = uuid4()
_MONTH_ANCHOR = datetime(2026, 6, 8, tzinfo=UTC)  # 6월 안의 어느 날
_IN_MONTH = datetime(2026, 6, 9, 3, 0, tzinfo=UTC)


def _item(*, category: str | None, captured_at: datetime = _IN_MONTH) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=captured_at),
        intent_instances=(IntentInstance(intent_type=Intent.MEMO),),
        summary="요약",
        category=category,
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _DigestRepo:
    def __init__(self, items: list[MochiItem], normalized: list[str] | None = None) -> None:
        self._items = items
        self._normalized = normalized or []
        self.updated: dict[UUID, str] = {}

    async def list_in_range(  # type: ignore[no-untyped-def]
        self, *, owner_id, captured_from, captured_to, intent, limit
    ):
        out = [i for i in self._items if captured_from <= i.source.captured_at < captured_to]
        out.sort(key=lambda i: i.source.captured_at, reverse=True)
        return out[:limit]

    async def list_normalized_categories(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        return self._normalized[:limit]

    async def bulk_update_category(self, *, owner_id, categories):  # type: ignore[no-untyped-def]
        self.updated.update(categories)


class _FakeLLM:
    def __init__(self, result: MonthlyDigestLLMResult) -> None:
        self._result = result
        self.calls = 0
        self.known_categories: list[str] | None = None

    async def generate(self, *, items, item_count, known_categories):  # type: ignore[no-untyped-def]
        self.calls += 1
        self.known_categories = known_categories
        return self._result


async def test_fewer_than_three_items_skips_llm_static_greeting() -> None:
    repo = _DigestRepo([_item(category="여행"), _item(category="개발")])
    llm = _FakeLLM(MonthlyDigestLLMResult(greeting="x", category_groups=()))
    result = await GenerateMonthlyDigest(repository=repo, llm=llm).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, month_start=_MONTH_ANCHOR
    )
    assert llm.calls == 0
    assert result.generated is False
    assert result.greeting == STATIC_GREETING
    assert result.groups == []
    assert repo.updated == {}


async def test_fine_to_coarse_normalizes_and_writes() -> None:
    a = _item(category="여행 준비")
    b = _item(category="여행 계획")
    c = _item(category="개발")
    repo = _DigestRepo([a, b, c])
    llm = _FakeLLM(
        MonthlyDigestLLMResult(
            greeting="이번 주엔 여행 준비를 많이 하셨네요.",
            category_groups=(
                CategoryGroup(coarse="여행", fines=("여행 준비", "여행 계획")),
                CategoryGroup(coarse="개발", fines=("개발",)),
            ),
        )
    )
    result = await GenerateMonthlyDigest(repository=repo, llm=llm).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, month_start=_MONTH_ANCHOR
    )
    assert result.generated is True
    assert repo.updated[a.id] == "여행"
    assert repo.updated[b.id] == "여행"
    # 라벨이 그대로여도(개발→개발) 정규화 마킹 위해 write 된다.
    assert repo.updated[c.id] == "개발"
    travel = next(g for g in result.groups if g.coarse == "여행")
    assert set(travel.item_ids) == {a.id, b.id}


async def test_unmapped_fine_keeps_original_category() -> None:
    a = _item(category="여행")
    cook = _item(category="요리")  # LLM 이 매핑에서 누락
    repo = _DigestRepo([a, cook, _item(category="개발")])
    llm = _FakeLLM(
        MonthlyDigestLLMResult(greeting="g", category_groups=(CategoryGroup(coarse="여행", fines=("여행",)),))
    )
    result = await GenerateMonthlyDigest(repository=repo, llm=llm).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, month_start=_MONTH_ANCHOR
    )
    assert repo.updated[cook.id] == "요리"  # 원본 유지(결정론)
    assert "요리" in {g.coarse for g in result.groups}


async def test_normalized_categories_passed_as_context() -> None:
    repo = _DigestRepo(
        [_item(category="여행 준비"), _item(category="개발"), _item(category="요리")],
        normalized=["여행", "개발"],
    )
    llm = _FakeLLM(MonthlyDigestLLMResult(greeting="g", category_groups=()))
    await GenerateMonthlyDigest(repository=repo, llm=llm).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, month_start=_MONTH_ANCHOR
    )
    assert llm.known_categories == ["여행", "개발"]


async def test_empty_llm_result_falls_back_to_static_greeting() -> None:
    # LLM 호출은 됐으나 빈 결과(파싱 실패 등) → 정적 greeting + 원본 category 유지.
    repo = _DigestRepo([_item(category="여행"), _item(category="개발"), _item(category="요리")])
    llm = _FakeLLM(MonthlyDigestLLMResult(greeting="", category_groups=()))
    result = await GenerateMonthlyDigest(repository=repo, llm=llm).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, month_start=_MONTH_ANCHOR
    )
    assert llm.calls == 1
    assert result.generated is True
    assert result.greeting == STATIC_GREETING
    assert len(repo.updated) == 3  # 마킹은 일어남(라벨은 원본)


# ── ListUpcomingActionables (다가올 미해결: todo + schedule) ──


def _actionable_item(*intents: Intent, deadline: str | None = None, date: str | None = None) -> MochiItem:
    payload = IntentPayload(deadline=deadline, date=date)
    instances = tuple(IntentInstance(intent_type=i, payload=payload) for i in intents)
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=_IN_MONTH),
        intent_instances=instances,
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _ActionableRepo:
    def __init__(self, pairs) -> None:  # type: ignore[no-untyped-def]
        self._pairs = pairs

    async def list_active_actionables_with_entities(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        return self._pairs[:limit]


async def test_upcoming_actionables_sorted_due_then_undated() -> None:
    todo = _actionable_item(Intent.TODO, deadline="2026-06-12")
    sched = _actionable_item(Intent.SCHEDULE, date="2026-06-11")
    undated = _actionable_item(Intent.TODO)
    repo = _ActionableRepo([(todo, ()), (sched, ()), (undated, ())])
    out = await ListUpcomingActionables(repository=repo).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, limit=10
    )
    assert [a.item.id for a in out] == [sched.id, todo.id, undated.id]
    assert out[0].is_schedule is True
    assert out[1].is_schedule is False
    assert out[2].due_at is None


async def test_actionable_prefers_todo_when_both_present() -> None:
    item = _actionable_item(Intent.SCHEDULE, Intent.TODO)
    todo_instance = next(i for i in item.intent_instances if i.intent_type == Intent.TODO)
    repo = _ActionableRepo([(item, ())])
    out = await ListUpcomingActionables(repository=repo).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, limit=10
    )
    assert out[0].is_schedule is False  # 닫을 수 있는 todo 우선
    assert out[0].instance_id == todo_instance.id


async def test_actionable_falls_back_to_entity_deadline() -> None:
    # payload 에 일시 없고 entities(kind='deadline')만 있을 때 그걸 파싱한다.
    item = _actionable_item(Intent.TODO)
    repo = _ActionableRepo([(item, (("deadline", "2026-06-12"),))])
    out = await ListUpcomingActionables(repository=repo).execute(  # type: ignore[arg-type]
        owner_id=_OWNER, limit=10
    )
    assert out[0].due_at is not None
    assert out[0].due_label == "2026-06-12"
