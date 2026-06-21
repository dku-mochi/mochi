"""홈탭 "예정 알림" 사용자 조정(B) 유스케이스 — reschedule(시간 옮기기) + veto(전체 끄기).

대상은 status='pending' 미래 알림. snooze("다음에")와 tune("시간 변경")은 둘 다 fire_at 을
사용자 지정 시각으로 옮기는 같은 연산이라 reschedule 하나로 통일(worker 무변경 — fire_at<=now
claim 이라 미래로 옮기면 자동 제외). veto 는 그 plan 을 cancel_plan(user_dismiss)으로 영구 정지.
"""

from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

from app.core.error_envelope import DomainError, NotFoundError
from app.modules.notifications.domain.recall_reaction import (
    RecallReactionRepositoryPort,
)
from app.modules.notifications.domain.upcoming_override import (
    UpcomingOverrideRepositoryPort,
)


class PastFireAtError(DomainError):
    """과거 시각으로는 옮길 수 없다 — 즉시 발송(또는 영영 안 감)을 방지."""

    code = "recall_upcoming.past_fire_at"
    status_code = 422


@dataclass(slots=True)
class RescheduleUpcomingCommand:
    owner_id: UUID
    event_id: UUID
    new_fire_at: datetime


@dataclass(slots=True)
class RescheduleUpcomingNotification:
    """pending 알림의 발송 시각을 사용자 지정 시각으로 옮긴다(프리셋·DatePicker 공용)."""

    override: UpcomingOverrideRepositoryPort

    async def execute(self, command: RescheduleUpcomingCommand) -> None:
        if command.new_fire_at <= datetime.now(UTC):
            raise PastFireAtError("Cannot reschedule into the past")
        updated = await self.override.reschedule(
            event_id=command.event_id,
            owner_id=command.owner_id,
            new_fire_at=command.new_fire_at,
        )
        if updated == 0:
            raise NotFoundError("Upcoming notification not found", code="recall_upcoming.not_found")


@dataclass(slots=True)
class VetoUpcomingCommand:
    owner_id: UUID
    event_id: UUID


@dataclass(slots=True)
class VetoUpcomingNotification:
    """이 항목 알림 전체 끄기 — 대상 pending skip + 그 plan 영구 cancel(user_dismiss).

    plan cancel 은 기존 `RecallReactionRepositoryPort.cancel_plan` 재사용 — 그 plan 의 나머지
    pending/deferred 미래 알림도 skipped(cancelled)로 대칭 정리된다(다음 단계 알림도 안 옴).
    """

    override: UpcomingOverrideRepositoryPort
    reactions: RecallReactionRepositoryPort

    async def execute(self, command: VetoUpcomingCommand) -> None:
        updated, plan_id = await self.override.veto_pending(
            event_id=command.event_id, owner_id=command.owner_id
        )
        if updated == 0:
            raise NotFoundError("Upcoming notification not found", code="recall_upcoming.not_found")
        if plan_id is not None:
            await self.reactions.cancel_plan(plan_id=plan_id, owner_id=command.owner_id)
