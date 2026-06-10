"""Conversations hexagonal outbound port.

모든 메서드가 ``owner_id`` 를 키워드로 강제한다 — cross-tenant 누설 방지 (기존 repository 규약).
"""

from datetime import datetime
from typing import Protocol
from uuid import UUID

from app.modules.conversations.domain.entities import Conversation, Message


class ConversationRepository(Protocol):
    async def create(self, *, owner_id: UUID, conversation: Conversation) -> None: ...

    async def find_by_id(self, *, owner_id: UUID, conversation_id: UUID) -> Conversation | None:
        """soft delete 된 대화는 None. owner-scoped."""
        ...

    async def list_for_owner(self, *, owner_id: UUID, limit: int) -> list[Conversation]:
        """updated_at 내림차순, deleted 제외. 히스토리 시트의 데이터 소스."""
        ...

    async def soft_delete(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        """deleted_at 마킹(행·메시지 보존). 없거나 다른 owner 면 False (→ 404)."""
        ...

    async def add_message(self, *, owner_id: UUID, message: Message) -> bool:
        """메시지(citations 포함) append + 대화 updated_at bump (히스토리 정렬 소스).

        대화가 없거나·soft delete 됐거나·다른 owner 면 **아무것도 쓰지 않고 False** —
        cross-tenant 쓰기·고아 행 차단.
        """
        ...

    async def list_messages(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        """대화의 전체 메시지(citations 포함)를 created_at 오름차순으로. 스냅샷 재조회용."""
        ...

    async def mark_stale_runs_failed(
        self, *, owner_id: UUID, conversation_id: UUID, started_before: datetime
    ) -> int:
        """``started_before`` 이전에 시작해 아직 running 인 run 을 failed 로 lazy repair.

        서버 재시작으로 in-process run 이 유실되면 행이 running 으로 영원히 남는다 —
        스케줄러 없이 스냅샷 읽기 시점에 줍는다. 갱신된 행 수 반환.
        """
        ...
