"""MochiItem 조회 use case 모음.

다른 모듈(예: agent)이 MochiItem 조회/소유권 검증이 필요할 때 이 application 진입점만 import한다.
infrastructure (`PostgresMochiItemRepository`) 직접 reach를 차단해 모듈 경계를 유지한다.
"""

from dataclasses import dataclass
from datetime import UTC, date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.shared.intent import Intent

# 사용자 체감 날짜(캘린더 그룹핑·마감일 해석)는 KST 기준. captured_at 은 UTC 저장.
KST = ZoneInfo("Asia/Seoul")
# 한 달치 항목 집계 상한 — 개인 사용 규모에서 충분(초과분은 잘림, 캘린더 점·개수 근사 허용).
_CALENDAR_FETCH_LIMIT = 2000
# 마감 임박 todo 정렬 전 active todo 스캔 상한(미완료라 보통 이보다 훨씬 적다).
_TODO_SCAN_LIMIT = 500
# entities[kind='deadline'].value 의 free-text 마감일 파싱 후보 포맷(ISO8601 우선 시도 후).
_DEADLINE_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d",
    "%Y/%m/%d %H:%M",
    "%Y/%m/%d",
    "%Y.%m.%d",
)
_DEADLINE_ENTITY_KIND = "deadline"


def make_mochi_item_repository(session: AsyncSession) -> MochiItemRepository:
    """Factory — 라우터/유스케이스 호출자가 infrastructure를 직접 알 필요 없게 한다."""
    return PostgresMochiItemRepository(session)


@dataclass(slots=True)
class GetMochiItemForOwner:
    repository: MochiItemRepository

    async def execute(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        return await self.repository.find_by_id(owner_id=owner_id, mochi_item_id=mochi_item_id)


# ---------- 캘린더 탭 read models ----------


@dataclass(slots=True, frozen=True)
class CalendarDay:
    """월간 캘린더의 하루 셀 집계. date 는 KST 기준 ``YYYY-MM-DD``."""

    date: str
    count: int
    representative_intent: Intent | None
    thumbnail_object_key: str | None


@dataclass(slots=True, frozen=True)
class UpcomingTodo:
    """미완료 todo + 파싱된 마감일. ``due_at`` 없으면 마감 미상(목록 뒤로)."""

    item: MochiItem
    due_at: datetime | None
    due_label: str | None


def _to_kst_date(value: datetime) -> date:
    """UTC(또는 tz-naive=UTC 가정) datetime → KST 달력 날짜."""
    aware = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
    return aware.astimezone(KST).date()


def _kst_month_bounds_utc(year: int, month: int) -> tuple[datetime, datetime]:
    """KST 기준 (해당 월 1일 00:00, 다음 달 1일 00:00) 을 UTC aware 로 반환."""
    start_kst = datetime(year, month, 1, tzinfo=KST)
    end_kst = (
        datetime(year + 1, 1, 1, tzinfo=KST)
        if month == 12
        else datetime(year, month + 1, 1, tzinfo=KST)
    )
    return start_kst.astimezone(UTC), end_kst.astimezone(UTC)


def _parse_deadline(value: str) -> datetime | None:
    """entities deadline free-text 를 datetime 으로. 실패하면 None(마감 미상)."""
    raw = value.strip()
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
        return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=KST)
    except ValueError:
        pass
    for fmt in _DEADLINE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=KST)
        except ValueError:
            continue
    return None


def _deadline_value(entities: tuple[tuple[str, str], ...]) -> str | None:
    for kind, value in entities:
        if kind == _DEADLINE_ENTITY_KIND:
            return value
    return None


# 캘린더 대표색 우선순위 — argmax(점수) 폐기(2026-06-04). 시간 민감한 일정이 대표.
_INTENT_PRIORITY = (Intent.SCHEDULE, Intent.TODO, Intent.KNOWLEDGE, Intent.MEMO)


def _representative_intent(group: list[MochiItem]) -> Intent | None:
    """그날의 대표 Intent = 고정 우선순위(schedule>todo>knowledge>memo) 중 존재하는 최상위.

    점수가 사라져 argmax 불가 — 의미 우선순위로 캘린더 칸 대표색을 정한다(대표 개념 자체는
    저장 안 함, read 시 projection).
    """
    present: set[Intent] = set()
    for item in group:
        present.update(item.intent_types)
    return next((i for i in _INTENT_PRIORITY if i in present), None)


def _first_thumbnail(group: list[MochiItem]) -> str | None:
    """그날 항목 중 object_key 가 있는 첫(최신) 이미지의 키."""
    for item in group:
        for image in item.source.image_refs:
            if image.object_key:
                return image.object_key
    return None


def _todo_sort_key(todo: UpcomingTodo) -> tuple[int, datetime]:
    """마감 있는 todo 를 임박순(오름차순) 먼저, 마감 미상은 뒤로(원래 순서 유지)."""
    if todo.due_at is not None:
        return (0, todo.due_at)
    return (1, datetime.max.replace(tzinfo=UTC))


@dataclass(slots=True)
class ListMochiItemsInRange:
    """날짜 구간 내 모찌 목록 — 캘린더에서 특정 날짜 선택 시 그날 목록."""

    repository: MochiItemRepository

    async def execute(
        self,
        *,
        owner_id: UUID,
        captured_from: datetime | None,
        captured_to: datetime | None,
        intent: Intent | None,
        limit: int,
    ) -> list[MochiItem]:
        return await self.repository.list_in_range(
            owner_id=owner_id,
            captured_from=captured_from,
            captured_to=captured_to,
            intent=intent,
            limit=limit,
        )


@dataclass(slots=True)
class GetMonthlyCalendar:
    """월간 캘린더 집계 — 날짜별 개수·대표 Intent·대표 썸네일."""

    repository: MochiItemRepository

    async def execute(self, *, owner_id: UUID, year: int, month: int) -> list[CalendarDay]:
        start_utc, end_utc = _kst_month_bounds_utc(year, month)
        items = await self.repository.list_in_range(
            owner_id=owner_id,
            captured_from=start_utc,
            captured_to=end_utc,
            intent=None,
            limit=_CALENDAR_FETCH_LIMIT,
        )
        # captured_at desc 입력 → 각 그룹의 첫 항목이 그날 최신(대표 썸네일/동률 tie-break).
        buckets: dict[str, list[MochiItem]] = {}
        for item in items:
            key = _to_kst_date(item.source.captured_at).isoformat()
            buckets.setdefault(key, []).append(item)
        days = [
            CalendarDay(
                date=day,
                count=len(group),
                representative_intent=_representative_intent(group),
                thumbnail_object_key=_first_thumbnail(group),
            )
            for day, group in buckets.items()
        ]
        days.sort(key=lambda d: d.date)
        return days


@dataclass(slots=True)
class ListUpcomingTodos:
    """미완료 todo 의 마감 임박 목록 — 마감일 파싱·정렬은 여기서(저장은 free-text)."""

    repository: MochiItemRepository

    async def execute(self, *, owner_id: UUID, limit: int) -> list[UpcomingTodo]:
        # 마감 임박순은 fetch(captured_at desc) 순서를 뒤집으므로, active todo 를 (사실상)전량
        # 스캔한 뒤 마감순 정렬 → 상위 limit. limit*N 으로 먼저 잘랐다가 '오래 전 캡처 + 임박
        # 마감' todo 를 놓치는 버그를 방지한다(active=미완료라 전량 스캔 비용이 작다).
        pairs = await self.repository.list_active_todos_with_entities(
            owner_id=owner_id, limit=_TODO_SCAN_LIMIT
        )
        todos: list[UpcomingTodo] = []
        for item, entities in pairs:
            due_label = _deadline_value(entities)
            due_at = _parse_deadline(due_label) if due_label else None
            todos.append(UpcomingTodo(item=item, due_at=due_at, due_label=due_label))
        todos.sort(key=_todo_sort_key)
        return todos[:limit]
