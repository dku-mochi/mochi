"""능동 회수 홈 피드 + 알림 landing(P5b) 도메인 — 읽기 전용 후보 조회 포트.

정본 `journal/2026-06-15-proactive-recall-ux-decision.md` §4(3단 구조)·§5(landing은 회수 목록/상세로 착지).

이번 마일스톤(트랙 A/B)의 피드 실데이터 = **active spaced plan 이 걸린 knowledge 항목**(다시 볼 지식).
related/context(트랙 C: 관련/맥락 후보 생성)는 범위 밖이라 DTO 에서 빈 배열·relatedCount=1 로 둔다(후속).

이 포트는 notification_plan/outbox(이 모듈 소유 테이블)만 읽어 후보 (item_id, recall_event_id) 를
낸다. item 표시필드(title/summary/channel/saved_at) 하이드레이션은 application 이 cross-module
`MochiItemRepository`(application factory)로 한다 — 모듈 경계(다른 모듈 infrastructure 직접 reach 금지).

프레임워크 import 금지(sqlalchemy 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True, slots=True)
class RecallFeedCandidate:
    """피드 1건의 후보 — active spaced plan 이 가리키는 item id + 그 item 의 최근 sent event id.

    ``recall_event_id`` 는 알림 landing 역참조용(없으면 None). 표시필드는 application 이 하이드레이션.
    """

    item_id: UUID
    recall_event_id: UUID | None


class RecallFeedRepositoryPort(ABC):
    """능동 회수 후보 조회 + 알림 landing 단건 해석. owner-scoped.

    P5 reaction 포트(쓰기)와 별개 — 단순 SELECT 만. 랭킹 공식은 미정이라 recency 정렬로 충분(후속).
    """

    @abstractmethod
    async def list_candidates(self, *, owner_id: UUID, limit: int) -> list[RecallFeedCandidate]:
        """owner 의 active spaced plan → source item id 를 plan recency 순으로(중복 item dedup).

        다른 plan_kind·non-active plan 은 제외. item 삭제·비-knowledge 필터는 하이드레이션이 거른다.
        빈손이면 [](정상). 각 후보에 그 item 의 최근 sent outbox event_id(없으면 None)를 붙인다.
        """

    @abstractmethod
    async def resolve_landing(
        self, *, owner_id: UUID, event_id: UUID
    ) -> UUID | None:
        """outbox event_id → source item id 해석(알림 landing). owner 스코프 필수, status 무관.

        event 가 없거나 다른 owner·source_item_id NULL 이면 None(→404 / 하이드레이션 실패도 404).
        """
