"""홈탭 "예정 알림"(다가오는 발송 예정 알림) 조회 도메인 — 읽기 전용 포트.

모찌가 자동 설계한 알림 중 **아직 안 보낸 미래 알림**(notification_outbox.status='pending',
fire_at>now)을 사용자에게 미리 보여줘 안심시킨다. "언제 알림이 갈지"를 미리 펼치는 예고 카드.

범위 = 마감/일정 알림만(kind IN ('deadline','nudge')). spaced 회수는 홈 RecallHero 가 이미
담당하므로 제외(중복·톤충돌 회피). title/body 는 worker 가 outbox INSERT 시 이미 렌더했으므로
cross-module 하이드레이션 불필요 — 이 포트가 outbox(이 모듈 소유)만 읽어 entry 를 완성한다.

프레임워크 import 금지(sqlalchemy 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID


@dataclass(frozen=True, slots=True)
class UpcomingNotification:
    """다가오는 예정 알림 1건 — outbox pending row 의 표시·타겟 정보.

    ``event_id`` 가 veto/reschedule 의 타겟 키. ``original_fire_at`` 는 사용자가 옮겼으면 모찌
    원안(없으면 None=미조정). ``kind`` 는 'deadline'|'nudge'(마감/일정·주기 넛지).
    """

    event_id: UUID
    kind: str
    fire_at: datetime
    title: str
    body: str
    original_fire_at: datetime | None
    item_id: UUID | None
    intent_id: UUID | None


class UpcomingFeedRepositoryPort(ABC):
    """다가오는 예정 알림 조회. owner-scoped, 읽기 전용 단순 SELECT(이 모듈 테이블만)."""

    @abstractmethod
    async def list_upcoming(self, *, owner_id: UUID, limit: int) -> list[UpcomingNotification]:
        """owner 의 pending 미래 알림(kind IN ('deadline','nudge'), fire_at>now) fire_at 오름차순.

        active plan 에 연결된 것만(LEFT JOIN status='active') — veto 로 cancel 된 plan 의 잔여는
        worker/cancel 이 skipped 로 치우므로 status='pending' 만으로도 충분하나 안전하게 가드한다.
        빈손이면 [](정상 — cold-start·전부 발송됨).
        """
