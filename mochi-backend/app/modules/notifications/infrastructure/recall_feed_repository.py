"""능동 회수 후보 조회 + 알림 landing 해석 — `RecallFeedRepositoryPort` 구현 (P5b).

P5 reaction repo(쓰기)와 별개 파일 — 읽기 전용 단순 SELECT. 이 모듈 소유 테이블만 만진다
(notification_plan/outbox). item 표시필드 하이드레이션은 application 이 cross-module 로 한다.

후보 = owner 의 active spaced plan 의 source_item_id(plan recency desc, 중복 item dedup).
각 후보에 그 item 의 최근 sent outbox event_id(없으면 NULL)를 붙인다 — 알림 landing 역참조용.
랭킹 공식은 미정이라 recency(plan.created_at desc)로 충분(후속).
"""

from uuid import UUID

from sqlalchemy import bindparam, desc, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.recall_feed import (
    RecallFeedCandidate,
    RecallFeedRepositoryPort,
)
from app.modules.notifications.infrastructure.orm import (
    NotificationOutboxRow,
    NotificationPlanRow,
)


class PostgresRecallFeedRepository(RecallFeedRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def list_candidates(self, *, owner_id: UUID, limit: int) -> list[RecallFeedCandidate]:
        # 트랙 C(recall outbox) 를 먼저(지금 맥락이라 신선) + 트랙 A(spaced knowledge) 합류,
        # 같은 item 은 dedup(recall 우선), recency 순. 랭킹 공식(ux-ui §7)은 후속 — 현재 recency.
        merged: list[RecallFeedCandidate] = []
        seen: set[UUID] = set()
        for cand in [
            *await self._recall_candidates(owner_id=owner_id, limit=limit),
            *await self._spaced_candidates(owner_id=owner_id, limit=limit),
        ]:
            if cand.item_id in seen:
                continue
            seen.add(cand.item_id)
            merged.append(cand)
            if len(merged) >= limit:
                break
        return merged

    async def _spaced_candidates(self, *, owner_id: UUID, limit: int) -> list[RecallFeedCandidate]:
        # active spaced plan → source_item_id. 같은 item 에 plan 이 여럿이어도 1행만(group by item),
        # 정렬 키는 그 item 의 가장 최근 plan.created_at(recency). source_item_id NULL plan 은 제외.
        latest_plan = func.max(NotificationPlanRow.created_at).label("latest_plan")
        plans = (
            select(
                NotificationPlanRow.source_item_id.label("item_id"),
                latest_plan,
            )
            .where(
                NotificationPlanRow.owner_id == owner_id,
                NotificationPlanRow.status == "active",
                NotificationPlanRow.plan_kind == "spaced",
                NotificationPlanRow.source_item_id.is_not(None),
            )
            .group_by(NotificationPlanRow.source_item_id)
            .order_by(desc(latest_plan))
            .limit(limit)
        )
        rows = (await self._session.execute(plans)).all()
        return [
            RecallFeedCandidate(
                item_id=row.item_id,
                recall_event_id=await self._latest_sent_event(owner_id=owner_id, item_id=row.item_id),
                source_kind="spaced",
            )
            for row in rows
        ]

    async def _recall_candidates(self, *, owner_id: UUID, limit: int) -> list[RecallFeedCandidate]:
        # kind=recall outbox(pending/sent) → source_item_id 별 최신 event, fire_at desc. 직행이라 plan 없음.
        # opened 필터는 바깥(최신 event 기준) — item 의 최신 event 를 열어봤으면 item 자체를 제외한다
        # ("열어본 회수는 피드에서 빠진다"). 안쪽에서 거르면 그 아래 옛 미open 행이 재부상해 카드가 부활.
        sql = text(
            """
            SELECT source_item_id AS item_id, event_id FROM (
              SELECT DISTINCT ON (source_item_id) source_item_id, event_id, fire_at, opened_at
              FROM notification_outbox
              WHERE owner_id = :owner AND kind = 'recall'
                AND status IN ('pending','sent') AND source_item_id IS NOT NULL
              ORDER BY source_item_id, fire_at DESC
            ) x
            WHERE x.opened_at IS NULL
            ORDER BY x.fire_at DESC
            LIMIT :limit
            """
        ).bindparams(bindparam("owner", owner_id), bindparam("limit", limit))
        rows = (await self._session.execute(sql)).all()
        return [
            RecallFeedCandidate(item_id=row.item_id, recall_event_id=row.event_id, source_kind="recall")
            for row in rows
        ]

    async def resolve_landing(self, *, owner_id: UUID, event_id: UUID) -> tuple[UUID, str] | None:
        # event → (source item id, kind). status 무관(sent 후 탭 OK), owner 스코프 필수.
        stmt = select(NotificationOutboxRow.source_item_id, NotificationOutboxRow.kind).where(
            NotificationOutboxRow.event_id == event_id,
            NotificationOutboxRow.owner_id == owner_id,
        )
        row = (await self._session.execute(stmt)).first()
        if row is None or row.source_item_id is None:
            return None
        return row.source_item_id, row.kind

    async def _latest_sent_event(self, *, owner_id: UUID, item_id: UUID) -> UUID | None:
        """그 item 의 가장 최근 sent outbox event_id(없으면 None). owner 스코프."""
        stmt = (
            select(NotificationOutboxRow.event_id)
            .where(
                NotificationOutboxRow.owner_id == owner_id,
                NotificationOutboxRow.source_item_id == item_id,
                NotificationOutboxRow.status == "sent",
            )
            .order_by(desc(NotificationOutboxRow.sent_at))
            .limit(1)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()
