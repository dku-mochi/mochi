"""DI 팩토리 — worker 가 notifications.infrastructure 를 직접 알 필요 없게 한다.

`make_push_token_repository` 와 동일 패턴(모듈 경계 유지). worker 는 이 팩토리로
`PlanRecallNotifications` 유스케이스를 조립한다.
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.application.plan_recall_notifications import (
    PlanRecallNotifications,
)
from app.modules.notifications.infrastructure.gemini_recall_planner import GeminiRecallPlanner
from app.modules.notifications.infrastructure.recall_context_provider import (
    PostgresRecallContextProvider,
    PostgresScheduledLookup,
)
from app.modules.notifications.infrastructure.recall_plan_repository import (
    PostgresRecallPlanRepository,
)


def make_plan_recall_notifications(
    session: AsyncSession, *, owner_id: UUID
) -> PlanRecallNotifications:
    """프로덕션 조립 — Gemini 플래너 + Postgres 어댑터. owner_id 는 get_scheduled owner-scope 용."""
    return PlanRecallNotifications(
        planner=GeminiRecallPlanner(owner_id=owner_id),
        context_provider=PostgresRecallContextProvider(session),
        repository=PostgresRecallPlanRepository(session),
        scheduled_lookup=PostgresScheduledLookup(session),
    )
