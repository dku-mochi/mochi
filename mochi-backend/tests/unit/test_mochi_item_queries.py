"""캘린더 탭 조회 use case 단위 테스트.

DB 통합 fixture(conftest)가 없어, repository 는 in-memory 스텁으로 대체하고
application 레이어의 KST 날짜 그룹핑·대표 Intent(고정 우선순위)·마감일 파싱/정렬만 검증한다.
owner_id 격리(SQL where)는 PostgresMochiItemRepository 코드 리뷰가 담당.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from app.modules.mochi_items.application.queries import (
    GetMonthlyCalendar,
    ListUpcomingTodos,
    _parse_deadline,
)
from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import IntentInstance
from app.shared.intent import Intent

_OWNER = uuid4()


def _item(
    *,
    captured_at: datetime,
    intent: Intent = Intent.MEMO,
    object_key: str | None = None,
    item_id: UUID | None = None,
) -> MochiItem:
    refs: tuple[ImageRef, ...] = ()
    if object_key is not None:
        refs = (ImageRef(sha256="a" * 64, mime_type="image/jpeg", byte_size=1, object_key=object_key),)
    return MochiItem(
        id=item_id or uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=captured_at, image_refs=refs),
        intent_instances=(IntentInstance(intent_type=intent),),
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


class _RangeRepo:
    """list_in_range 만 구현하는 캘린더용 스텁 (captured_at desc 반환)."""

    def __init__(self, items: list[MochiItem]) -> None:
        self._items = items

    async def list_in_range(self, *, owner_id, captured_from, captured_to, intent, limit):  # type: ignore[no-untyped-def]
        out = []
        for item in self._items:
            ts = item.source.captured_at
            if captured_from is not None and ts < captured_from:
                continue
            if captured_to is not None and ts >= captured_to:
                continue
            if intent is not None and intent not in item.intent_types:
                continue
            out.append(item)
        out.sort(key=lambda i: i.source.captured_at, reverse=True)
        return out[:limit]


class _TodoRepo:
    """list_active_todos_with_entities 만 구현하는 todo용 스텁."""

    def __init__(self, pairs) -> None:  # type: ignore[no-untyped-def]
        self._pairs = pairs

    async def list_active_todos_with_entities(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        return self._pairs[:limit]


async def test_monthly_calendar_groups_by_kst_date_and_representative_intent() -> None:
    items = [
        _item(intent=Intent.TODO, captured_at=datetime(2026, 6, 1, 1, 0, tzinfo=UTC), object_key="k1"),
        _item(intent=Intent.TODO, captured_at=datetime(2026, 6, 1, 2, 0, tzinfo=UTC)),
        _item(intent=Intent.SCHEDULE, captured_at=datetime(2026, 6, 1, 3, 0, tzinfo=UTC)),
        _item(intent=Intent.KNOWLEDGE, captured_at=datetime(2026, 6, 2, 5, 0, tzinfo=UTC)),
    ]
    use_case = GetMonthlyCalendar(repository=_RangeRepo(items))  # type: ignore[arg-type]
    days = await use_case.execute(owner_id=_OWNER, year=2026, month=6)

    by_date = {d.date: d for d in days}
    assert by_date["2026-06-01"].count == 3
    # 대표색 = 고정 우선순위(schedule>todo>knowledge>memo) — 그날 schedule 이 있으면 schedule.
    assert by_date["2026-06-01"].representative_intent == Intent.SCHEDULE
    assert by_date["2026-06-01"].thumbnail_object_key == "k1"  # 유일한 object_key
    assert by_date["2026-06-02"].count == 1
    assert by_date["2026-06-02"].representative_intent == Intent.KNOWLEDGE
    assert by_date["2026-06-02"].thumbnail_object_key is None
    assert [d.date for d in days] == sorted(d.date for d in days)  # 날짜 오름차순


async def test_monthly_calendar_uses_kst_month_boundary() -> None:
    # 2026-05-31 15:30 UTC == 2026-06-01 00:30 KST → 6월에 포함
    inside = _item(captured_at=datetime(2026, 5, 31, 15, 30, tzinfo=UTC))
    # 2026-05-31 14:00 UTC == 2026-05-31 23:00 KST → 5월(6월 제외)
    outside = _item(captured_at=datetime(2026, 5, 31, 14, 0, tzinfo=UTC))
    use_case = GetMonthlyCalendar(repository=_RangeRepo([inside, outside]))  # type: ignore[arg-type]
    days = await use_case.execute(owner_id=_OWNER, year=2026, month=6)

    dates = {d.date for d in days}
    assert "2026-06-01" in dates
    assert all(d.date.startswith("2026-06") for d in days)


async def test_upcoming_todos_sort_deadline_then_undated_last() -> None:
    near = _item(intent=Intent.TODO, captured_at=datetime(2026, 6, 1, tzinfo=UTC))
    far = _item(intent=Intent.TODO, captured_at=datetime(2026, 6, 1, tzinfo=UTC))
    undated = _item(intent=Intent.TODO, captured_at=datetime(2026, 6, 1, tzinfo=UTC))
    pairs = [
        (far, (("deadline", "2026-12-31 23:59"),)),
        (undated, (("topic", "발표 준비"),)),
        (near, (("deadline", "2026-06-10"),)),
    ]
    use_case = ListUpcomingTodos(repository=_TodoRepo(pairs))  # type: ignore[arg-type]
    todos = await use_case.execute(owner_id=_OWNER, limit=10)

    assert [t.item.id for t in todos] == [near.id, far.id, undated.id]
    assert todos[2].due_at is None
    assert todos[2].due_label == "발표 준비" or todos[2].due_label is None


async def test_upcoming_todos_respects_limit() -> None:
    pairs = [
        (
            _item(intent=Intent.TODO, captured_at=datetime(2026, 6, i + 1, tzinfo=UTC)),
            (("deadline", f"2026-06-{i + 1:02d}"),),
        )
        for i in range(5)
    ]
    use_case = ListUpcomingTodos(repository=_TodoRepo(pairs))  # type: ignore[arg-type]
    todos = await use_case.execute(owner_id=_OWNER, limit=2)
    assert len(todos) == 2


def test_parse_deadline_handles_common_formats() -> None:
    assert _parse_deadline("2026-05-30 23:59") is not None
    assert _parse_deadline("2026-05-30") is not None
    assert _parse_deadline("2026-05-30T23:59:00") is not None
    assert _parse_deadline("2026/05/30") is not None
    assert _parse_deadline("내일까지") is None
    assert _parse_deadline("   ") is None
    assert _parse_deadline("") is None


def test_parse_deadline_naive_input_assumed_kst() -> None:
    parsed = _parse_deadline("2026-05-30 09:00")
    assert parsed is not None
    assert parsed.utcoffset() is not None  # KST tz 부여됨
