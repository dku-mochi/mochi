"""알림 페이지 "지난 알림"(이미 보낸 알림) 조회 도메인 — 읽기 전용 포트.

모찌가 이미 보낸 알림(notification_outbox.status='sent')을 최근 발송 순으로 보여준다.
"이미 왔던 알림" 이력 — ``opened_at``/``dismissed_at`` 로 사용자가 열어봤는지/무시했는지 함께 표시.

범위 = 종류 무관(deadline/nudge/recall/spaced 등 받은 알림 전부). 예정 알림과 달리 kind 제한 없음.
title/body 는 worker 가 outbox INSERT 시 이미 렌더했으므로 cross-module 하이드레이션 불필요 —
이 포트가 outbox(이 모듈 소유)만 읽어 entry 를 완성한다.

프레임워크 import 금지(sqlalchemy 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID


@dataclass(frozen=True, slots=True)
class SentNotification:
    """이미 보낸 알림 1건 — outbox sent row 의 표시 정보.

    ``sent_at`` 발송 시각. ``opened_at`` 사용자가 탭한 시각(없으면 None=안 열어봄),
    ``dismissed_at`` 무시한 시각(없으면 None). ``kind`` 는 'deadline'|'nudge'|'recall' 등.
    """

    event_id: UUID
    kind: str
    sent_at: datetime
    opened_at: datetime | None
    dismissed_at: datetime | None
    title: str
    body: str
    item_id: UUID | None
    intent_id: UUID | None


class SentFeedRepositoryPort(ABC):
    """이미 보낸 알림 조회. owner-scoped, 읽기 전용 단순 SELECT(이 모듈 테이블만)."""

    @abstractmethod
    async def list_sent(
        self, *, owner_id: UUID, limit: int
    ) -> list[SentNotification]:
        """owner 의 발송 완료 알림(status='sent') sent_at 내림차순(최근 순). 종류 제한 없음.

        빈손이면 [](정상 — 아직 받은 알림 없음).
        """
