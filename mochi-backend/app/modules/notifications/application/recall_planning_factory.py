"""DI 팩토리 — worker 가 notifications.infrastructure 를 직접 알 필요 없게 한다.

`make_push_token_repository` 와 동일 패턴(모듈 경계 유지). worker 는 이 팩토리로
`PlanRecallNotifications` 유스케이스를 조립한다.
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.modules.mochi_items.application.queries import make_mochi_item_repository
from app.modules.notifications.application.generate_recall_candidates import (
    GenerateRecallCandidates,
)
from app.modules.notifications.application.plan_recall_notifications import (
    PlanRecallNotifications,
)
from app.modules.notifications.infrastructure.gemini_recall_gate import GeminiRecallGate
from app.modules.notifications.infrastructure.gemini_recall_planner import GeminiRecallPlanner
from app.modules.notifications.infrastructure.recall_candidate_repository import (
    PostgresRecallCandidateRepository,
)
from app.modules.notifications.infrastructure.recall_context_provider import (
    PostgresRecallContextProvider,
    PostgresScheduledLookup,
)
from app.modules.notifications.infrastructure.recall_plan_repository import (
    PostgresRecallPlanRepository,
)


def make_plan_recall_notifications(session: AsyncSession, *, owner_id: UUID) -> PlanRecallNotifications:
    """프로덕션 조립 — Gemini 플래너 + Postgres 어댑터. owner_id 는 get_scheduled owner-scope 용."""
    return PlanRecallNotifications(
        planner=GeminiRecallPlanner(owner_id=owner_id),
        context_provider=PostgresRecallContextProvider(session),
        repository=PostgresRecallPlanRepository(session),
        scheduled_lookup=PostgresScheduledLookup(session),
    )


def make_generate_recall_candidates(session: AsyncSession) -> GenerateRecallCandidates:
    """트랙 C 후보 생성(P7~P9) 조립 — ANN repo + mochi_items(application factory)."""
    s = get_settings()
    return GenerateRecallCandidates(
        candidates=PostgresRecallCandidateRepository(session),
        mochi_items=make_mochi_item_repository(session),
        gate=GeminiRecallGate(),
        min_score=s.recall_candidate_min_score,
        overfetch_limit=s.recall_overfetch_limit,
        gate_topn=s.recall_gate_topn,
        near_dup_score=s.recall_near_dup_score,
        gate_enabled=s.recall_gate_enabled,
        gate_dry_run=s.recall_gate_dry_run,
        dedup_cooldown_days=s.recall_dedup_cooldown_days,
        dismiss_cooldown_days=s.recall_dismiss_cooldown_days,
        owner_cooldown_hours=s.recall_owner_cooldown_hours,
        expires_days=s.recall_expires_days,
    )
