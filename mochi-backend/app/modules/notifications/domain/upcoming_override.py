"""홈탭 "예정 알림" 사용자 조정(veto/reschedule) 도메인 — pending outbox override 포트.

제품 원칙: 모찌가 정하고(기본 ON), 사용자는 **거부·조정만** 한다. 대상은 status='pending' 인
미래 알림(reaction 포트는 status='sent' 전제라 재사용 불가 — 별도 포트).

- reschedule(시간 옮기기): pending fire_at 을 사용자 지정 시각으로 갱신 + 첫 1회 original_fire_at 보존.
- veto(이 항목 알림 전체 끄기): 대상 pending 을 skipped(user_veto) + 그 plan 을 영구 cancel
  (cancel_plan 재사용은 application 이 RecallReactionRepositoryPort 로 조립). 여기선 plan_id 만 회수.

owner-scope atomic UPDATE 가드(cross-tenant 차단). 프레임워크 import 금지(sqlalchemy 는 infra 한정).
"""

from abc import ABC, abstractmethod
from datetime import datetime
from uuid import UUID


class UpcomingOverrideRepositoryPort(ABC):
    """pending outbox 의 reschedule + veto(pending skip). owner-scoped, atomic."""

    @abstractmethod
    async def reschedule(self, *, event_id: UUID, owner_id: UUID, new_fire_at: datetime) -> int:
        """pending(fire_at>now) 인 owner 의 outbox 발송 시각을 new_fire_at 으로 갱신.

        첫 조정 때만 original_fire_at=COALESCE(original_fire_at, fire_at) 로 원안 보존.
        갱신된 행수 반환(0=남의 event·이미 sent/skipped·과거 → 호출부가 404 분기).
        """

    @abstractmethod
    async def veto_pending(self, *, event_id: UUID, owner_id: UUID) -> tuple[int, UUID | None]:
        """pending(fire_at>now) 인 owner 의 outbox 1건을 skipped(user_veto) 마킹.

        (갱신 행수, 그 행의 plan_id) 반환. 행수 0 → 404 분기. plan_id 가 있으면 호출부가
        cancel_plan(user_dismiss)으로 그 plan 의 나머지 미래 알림까지 영구 정지한다(전체 끄기).
        """
