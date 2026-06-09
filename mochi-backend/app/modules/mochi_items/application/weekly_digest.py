"""주간 정리 use case — 그 주 item 의 카테고리 정규화 + "모찌의 한마디" 생성.

LLM 1회 호출로 fine→coarse 매핑과 greeting 을 받아, 그 주 item 의 ``category`` 를
정규화(**write**)한다. item 마다 제각각 category 가 생기는 파편화를 점진 수렴시키는 것이 목적이다.
(캘린더 ``_representative_intent`` 같은 read projection 과 달리 여기는 실제 DB write.)

그 주 item 이 ``_MIN_ITEMS_FOR_LLM`` 미만이면 LLM 을 호출하지 않고 정적 인사로 폴백한다 —
초기 사용자/조용한 주에 빈 LLM 비용을 쓰지 않는다.
"""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from app.modules.mochi_items.domain.digest_port import DigestInputItem, WeeklyDigestLLM
from app.modules.mochi_items.domain.ports import MochiItemRepository

# 사용자 체감 주(週)는 KST 월요일 시작. captured_at 은 UTC 저장이라 경계 변환이 필요하다.
KST = ZoneInfo("Asia/Seoul")
_MIN_ITEMS_FOR_LLM = 3
_MAX_LLM_ITEMS = 30
_RECENT_CATEGORY_LIMIT = 40
_WEEK_FETCH_LIMIT = 500
_FALLBACK_GROUP = "그 외"
STATIC_GREETING = "이번 주는 차분했네요. 모아둔 기록은 제가 잘 정리해 둘게요."


@dataclass(frozen=True, slots=True)
class DigestGroupView:
    coarse: str
    item_ids: tuple[UUID, ...]


@dataclass(slots=True)
class WeeklyDigestResult:
    greeting: str
    groups: list[DigestGroupView]
    generated: bool


def _week_bounds_utc(week_start: datetime) -> tuple[datetime, datetime]:
    """``week_start``(어느 tz 든) 를 KST 그 주 월요일 00:00 으로 정규화 → ``[start, start+7d)`` UTC.

    iOS 가 보내는 weekStart 가 어긋나도 서버가 단일 기준(KST 월요일)으로 재정규화해
    홈 카드 집계(currentWeekInterval, firstWeekday=월)와 동일 구간을 보장한다.
    """
    aware = week_start if week_start.tzinfo is not None else week_start.replace(tzinfo=KST)
    kst_dt = aware.astimezone(KST)
    monday = (kst_dt - timedelta(days=kst_dt.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return monday.astimezone(UTC), (monday + timedelta(days=7)).astimezone(UTC)


@dataclass(slots=True)
class GenerateWeeklyDigest:
    repository: MochiItemRepository
    llm: WeeklyDigestLLM

    async def execute(self, *, owner_id: UUID, week_start: datetime) -> WeeklyDigestResult:
        start_utc, end_utc = _week_bounds_utc(week_start)
        items = await self.repository.list_in_range(
            owner_id=owner_id,
            captured_from=start_utc,
            captured_to=end_utc,
            intent=None,
            limit=_WEEK_FETCH_LIMIT,
        )
        if len(items) < _MIN_ITEMS_FOR_LLM:
            return WeeklyDigestResult(greeting=STATIC_GREETING, groups=[], generated=False)

        llm_items = [
            DigestInputItem(category=it.category, title=(it.summary or None)) for it in items[:_MAX_LLM_ITEMS]
        ]
        known = await self.repository.list_normalized_categories(
            owner_id=owner_id, limit=_RECENT_CATEGORY_LIMIT
        )
        result = await self.llm.generate(items=llm_items, item_count=len(items), known_categories=known)

        # fine → coarse 매핑 (LLM 이 echo 한 fine 문자열 기준)
        fine_to_coarse: dict[str, str] = {
            fine: group.coarse for group in result.category_groups for fine in group.fines
        }

        # 그 주 각 item 의 새 category 결정 + 응답 그룹 구성.
        # 매핑에 없는 fine 은 원본 유지(결정론) — LLM 이 누락해도 데이터 유실 없음.
        # category 가 있는 모든 item 을 write 한다(라벨이 그대로여도) — 정규화를 "거쳤음"을
        # 마킹해야 다음 주 known_categories(연쇄 톤앤매너)에 포함된다.
        updates: dict[UUID, str] = {}
        grouped: dict[str, list[UUID]] = {}
        for it in items:  # captured_at desc — item_ids 순서 보존
            coarse = fine_to_coarse.get(it.category) if it.category else None
            new_category = coarse or it.category
            if new_category:
                updates[it.id] = new_category
            grouped.setdefault(new_category or _FALLBACK_GROUP, []).append(it.id)

        if updates:
            await self.repository.bulk_update_category(owner_id=owner_id, categories=updates)

        groups = [DigestGroupView(coarse=label, item_ids=tuple(ids)) for label, ids in grouped.items()]
        return WeeklyDigestResult(greeting=result.greeting or STATIC_GREETING, groups=groups, generated=True)
