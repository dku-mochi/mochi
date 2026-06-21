"""notification_plan 영속 — `RecallPlanRepositoryPort` 구현 (P2).

같은 source_intent 1 active 불변(plan 폭증 방지, codex-3) + supersede(같은 트랜잭션 교체).
이 시점엔 outbox 가 없어 outbox skip(schema.md §4-2)은 P3 cron 몫이다.
"""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.recall_plan import PlanKind
from app.modules.notifications.domain.recall_planning import (
    RecallPlanRepositoryPort,
    StoredPlan,
)
from app.modules.notifications.infrastructure.orm import NotificationPlanRow

_DSL_VERSION = "1"


class PostgresRecallPlanRepository(RecallPlanRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_active_by_intent(self, *, owner_id: UUID, source_intent_id: UUID) -> StoredPlan | None:
        stmt = select(NotificationPlanRow.id, NotificationPlanRow.source_intent_id).where(
            NotificationPlanRow.owner_id == owner_id,
            NotificationPlanRow.source_intent_id == source_intent_id,
            NotificationPlanRow.status == "active",
        )
        row = (await self._session.execute(stmt)).first()
        if row is None:
            return None
        return StoredPlan(id=row.id, source_intent_id=row.source_intent_id)

    async def insert_plan(
        self,
        *,
        owner_id: UUID,
        source_intent_id: UUID,
        source_item_id: UUID,
        plan_kind: PlanKind,
        stages: dict[str, Any],
        generated_model: str,
        next_eligible_at: datetime,
    ) -> UUID:
        row = NotificationPlanRow(
            owner_id=owner_id,
            source_intent_id=source_intent_id,
            plan_kind=plan_kind.value,
            dsl_version=_DSL_VERSION,
            generated_model=generated_model,
            source_item_id=source_item_id,
            stages=stages,
            next_eligible_at=next_eligible_at,
        )
        # savepoint 로 감싼다 — ux_notification_plan_active_intent(active 1개) 충돌(동시 워커)이
        # 나도 이 한 건만 롤백되고 같은 run 의 앞선 후보 insert·세션은 살아남는다(H-3). IntegrityError 는
        # 유스케이스로 전파돼 skip 처리된다.
        async with self._session.begin_nested():
            self._session.add(row)
            await self._session.flush()  # id 채우기(insert_default=uuid4 는 flush 시점)
        return row.id

    async def supersede(self, *, owner_id: UUID, old_plan_id: UUID, new_plan_id: UUID) -> None:
        # owner-scope + status='active' 가드 — cross-tenant update·이미 종료된 plan 재교체 차단(§4-3).
        # cancelled_at 은 비운다: schema.md §1 상 cancelled_at=영구 dismiss 시각이라 supersede(재평가 교체)
        # 에선 의미상 비우는 게 맞다(cancel_reason='superseded' 만 사유로 기록).
        stmt = (
            update(NotificationPlanRow)
            .where(
                NotificationPlanRow.id == old_plan_id,
                NotificationPlanRow.owner_id == owner_id,
                NotificationPlanRow.status == "active",
            )
            .values(status="superseded", superseded_by=new_plan_id, cancel_reason="superseded")
        )
        await self._session.execute(stmt)
        await self._session.flush()
