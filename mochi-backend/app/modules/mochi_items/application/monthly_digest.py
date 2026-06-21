"""월간 정리 use case — 그 달 item 의 카테고리 정규화 + "모찌의 한마디" 생성.

LLM 1회 호출로 fine→coarse 매핑과 greeting 을 받아, 그 달 item 의 ``category`` 를
정규화(**write**)한다. item 마다 제각각 category 가 생기는 파편화를 점진 수렴시키는 것이 목적이다.
(캘린더 ``_representative_intent`` 같은 read projection 과 달리 여기는 실제 DB write.)

그 달 item 이 ``_MIN_ITEMS_FOR_LLM`` 미만이면 LLM 을 호출하지 않고 정적 인사로 폴백한다 —
초기 사용자/조용한 달에 빈 LLM 비용을 쓰지 않는다.
"""

from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from app.modules.mochi_items.domain.digest_port import DigestInputItem, MonthlyDigestLLM
from app.modules.mochi_items.domain.ports import MochiItemRepository

# 사용자 체감 달(月)은 KST 1일 시작. captured_at 은 UTC 저장이라 경계 변환이 필요하다.
KST = ZoneInfo("Asia/Seoul")
_MIN_ITEMS_FOR_LLM = 3
_MAX_LLM_ITEMS = 30
# distinct 라벨 기준 (row 아님 — repository 참조). 사용자 카테고리가 50개를 넘는 일은
# 드물다는 가정 — 사실상 전체 vocabulary 를 컨텍스트로 준다.
_RECENT_CATEGORY_LIMIT = 50
# 한 달 분량 — 홈 월간 리포트 집계(currentMonthInterval, 상한 800)와 같은 기준.
_MONTH_FETCH_LIMIT = 800
_FALLBACK_GROUP = "그 외"
STATIC_GREETING = "이번 달은 차분했네요. 모아둔 기록은 제가 잘 정리해 둘게요."


@dataclass(frozen=True, slots=True)
class DigestGroupView:
    coarse: str
    item_ids: tuple[UUID, ...]


@dataclass(slots=True)
class MonthlyDigestResult:
    greeting: str
    groups: list[DigestGroupView]
    generated: bool


def _month_bounds_utc(month_anchor: datetime) -> tuple[datetime, datetime]:
    """``month_anchor``(어느 tz 든) 를 KST 그 달 1일 00:00 으로 정규화 → ``[first, 다음달 first)`` UTC.

    iOS 가 보내는 monthStart 가 어긋나도(달 안 어느 시점이든) 서버가 단일 기준(KST 1일)으로
    재정규화해 홈 월간 리포트 집계(currentMonthInterval)와 동일 구간을 보장한다.
    """
    aware = month_anchor if month_anchor.tzinfo is not None else month_anchor.replace(tzinfo=KST)
    kst_dt = aware.astimezone(KST)
    first = kst_dt.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if first.month == 12:
        nxt = first.replace(year=first.year + 1, month=1)
    else:
        nxt = first.replace(month=first.month + 1)
    return first.astimezone(UTC), nxt.astimezone(UTC)


@dataclass(slots=True)
class GenerateMonthlyDigest:
    repository: MochiItemRepository
    llm: MonthlyDigestLLM

    async def execute(self, *, owner_id: UUID, month_start: datetime) -> MonthlyDigestResult:
        start_utc, end_utc = _month_bounds_utc(month_start)
        items = await self.repository.list_in_range(
            owner_id=owner_id,
            captured_from=start_utc,
            captured_to=end_utc,
            intent=None,
            limit=_MONTH_FETCH_LIMIT,
        )
        if len(items) < _MIN_ITEMS_FOR_LLM:
            return MonthlyDigestResult(greeting=STATIC_GREETING, groups=[], generated=False)

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

        # 그 달 각 item 의 새 category 결정 + 응답 그룹 구성.
        # 매핑에 없는 fine 은 원본 유지(결정론) — LLM 이 누락해도 데이터 유실 없음.
        # category 가 있는 모든 item 을 write 한다(라벨이 그대로여도) — 정규화를 "거쳤음"을
        # 마킹해야 다음 달 known_categories(연쇄 톤앤매너)에 포함된다.
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
        return MonthlyDigestResult(greeting=result.greeting or STATIC_GREETING, groups=groups, generated=True)
