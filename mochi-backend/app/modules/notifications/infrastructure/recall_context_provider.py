"""알림 플래너 맥락 수집 — `RecallContextProviderPort` + `ScheduledLookup` 구현 (P2).

맥락: 최근 저장 10 / 유사 저장 10(임베딩) / 과거 알림 10(opened 시각만). notification-agent.md §2.2.

모듈 경계: mochi_items 접근은 `mochi_items.application`(factory)만 통한다(agent worker 와 동형 —
infrastructure 직접 reach 없음). 유사 검색은 search 모듈을 cross-import 하면 경계 위반이라(search 에
재사용 가능한 application factory 부재), `embeddings`/`mochi_items` 테이블에 대한 raw cosine SQL 로
직접 조회한다(postgres_index.similar 와 동일한 pgvector `<=>` 패턴, 임베딩 미설정 시 자연히 0행).
"""

from datetime import UTC, datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.mochi_items.application.queries import make_mochi_item_repository
from app.modules.notifications.domain.recall_planning import (
    PastNotification,
    PlanningContext,
    RecallContextProviderPort,
    RecentItem,
    ScheduledLookup,
    ScheduledNotification,
)
from app.modules.notifications.infrastructure.orm import NotificationOutboxRow

# 단일 KST 전제(codex-1) — 모든 시각 판정은 owner KST local 기준.
_KST = timezone(timedelta(hours=9))

_RECENT_LIMIT = 10
_SIMILAR_LIMIT = 10
_PAST_LIMIT = 10
_SIMILAR_MIN_SCORE = 0.5


class PostgresRecallContextProvider(RecallContextProviderPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session
        self._items = make_mochi_item_repository(session)

    async def gather(self, *, owner_id: UUID, mochi_item_id: UUID) -> PlanningContext:
        now_kst = datetime.now(UTC).astimezone(_KST)
        recent = await self._recent(owner_id=owner_id)
        similar = await self._similar(owner_id=owner_id, mochi_item_id=mochi_item_id)
        past = await self._past_notifications(owner_id=owner_id)
        return PlanningContext(now_kst=now_kst, recent=recent, similar=similar, past_notifications=past)

    async def _recent(self, *, owner_id: UUID) -> list[RecentItem]:
        items = await self._items.list_recent(owner_id=owner_id, limit=_RECENT_LIMIT)
        return [
            RecentItem(
                title=it.display_title,
                summary=it.summary,
                category=it.category,
                created_at=it.created_at,
            )
            for it in items
        ]

    async def _similar(self, *, owner_id: UUID, mochi_item_id: UUID) -> list[RecentItem]:
        # postgres_index.similar 와 동일 cosine 패턴. 임베딩 미설정/미색인이면 target 서브쿼리가
        # NULL → 0행(자연 degrade). 콜론 토큰을 주석에 쓰지 않는다(SQLAlchemy text() 파싱, 2026-06-14).
        sql = text(
            """
            WITH target AS (
                SELECT e.embedding AS emb
                FROM embeddings e
                JOIN mochi_items c ON c.id = e.mochi_item_id
                WHERE c.id = :target_id AND c.owner_id = :owner_id AND c.deleted_at IS NULL
                LIMIT 1
            )
            SELECT c.id AS mochi_item_id, c.summary AS summary, c.category AS category
            FROM embeddings e
            JOIN mochi_items c ON c.id = e.mochi_item_id
            WHERE c.owner_id = :owner_id
              AND c.deleted_at IS NULL
              AND c.id <> :target_id
              AND (SELECT emb FROM target) IS NOT NULL
              AND 1.0 - (e.embedding <=> (SELECT emb FROM target)) >= :min_score
            ORDER BY e.embedding <=> (SELECT emb FROM target)
            LIMIT :limit
            """
        ).bindparams(
            bindparam("target_id", mochi_item_id),
            bindparam("owner_id", owner_id),
            bindparam("min_score", _SIMILAR_MIN_SCORE),
            bindparam("limit", _SIMILAR_LIMIT),
        )
        rows = (await self._session.execute(sql)).all()
        return [
            RecentItem(title=None, summary=row.summary, category=row.category, created_at=None)
            for row in rows
        ]

    async def _past_notifications(self, *, owner_id: UUID) -> list[PastNotification]:
        # 발송된(sent) 알림만. opened_at 만 양성 신호 — 안 누름 ≠ negative(§6). 최근 발송순.
        stmt = (
            NotificationOutboxRow.__table__.select()
            .where(
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.status == "sent",
            )
            .order_by(NotificationOutboxRow.fire_at.desc())
            .limit(_PAST_LIMIT)
        )
        rows = (await self._session.execute(stmt)).all()
        return [
            PastNotification(title=row.title, fire_at=row.fire_at, opened_at=row.opened_at) for row in rows
        ]


class PostgresScheduledLookup(ScheduledLookup):
    """`get_scheduled(date)` — 그날(KST) fire 예정/완료 알림 조회(묶기·중복방지)."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def for_date(self, *, owner_id: UUID, date_kst: str) -> list[ScheduledNotification]:
        # date_kst('YYYY-MM-DD') 의 KST 하루 경계를 UTC 로 변환해 fire_at 범위 조회.
        try:
            day = datetime.strptime(date_kst[:10], "%Y-%m-%d").date()
        except ValueError:
            return []
        start_kst = datetime(day.year, day.month, day.day, tzinfo=_KST)
        end_kst = start_kst + timedelta(days=1)
        stmt = (
            NotificationOutboxRow.__table__.select()
            .where(
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.fire_at >= start_kst.astimezone(UTC),
                NotificationOutboxRow.fire_at < end_kst.astimezone(UTC),
                NotificationOutboxRow.status.in_(("pending", "deferred", "sent")),
            )
            .order_by(NotificationOutboxRow.fire_at)
        )
        rows = (await self._session.execute(stmt)).all()
        return [
            ScheduledNotification(title=row.title, fire_at=row.fire_at.astimezone(_KST), kind=row.kind)
            for row in rows
        ]
