"""대화 조회·삭제 use case — 채팅 탭 히스토리 시트·스냅샷 재조회의 application 레이어.

스냅샷(GET messages)이 stale run lazy repair 를 겸한다 — 서버 재시작으로 in-process run 이
유실되면 running 행이 영원히 남는데, 스케줄러 없이 읽기 시점에 failed 로 줍는다
(iOS 는 포그라운드 복귀 시 스냅샷을 재조회하므로 사용자가 보는 순간엔 항상 정합).
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.modules.conversations.domain.entities import (
    Conversation,
    Message,
    stale_threshold_seconds,
)
from app.modules.conversations.domain.ports import ConversationRepository


def make_conversation_repository(session: AsyncSession) -> ConversationRepository:
    """presentation 이 infrastructure 를 직접 import 하지 않도록 하는 조립 지점."""
    from app.modules.conversations.infrastructure.repository import PostgresConversationRepository

    return PostgresConversationRepository(session)


@dataclass(frozen=True, slots=True)
class ListConversations:
    repository: ConversationRepository

    async def execute(self, *, owner_id: UUID, limit: int = 50) -> list[Conversation]:
        return await self.repository.list_for_owner(owner_id=owner_id, limit=limit)


@dataclass(frozen=True, slots=True)
class ConversationSnapshot:
    conversation: Conversation
    messages: list[Message]


@dataclass(frozen=True, slots=True)
class GetConversationSnapshot:
    """대화 메시지 전체 스냅샷 (+stale run lazy repair). 대화가 없거나 다른 owner 면 None."""

    repository: ConversationRepository

    async def execute(self, *, owner_id: UUID, conversation_id: UUID) -> ConversationSnapshot | None:
        conversation = await self.repository.find_by_id(owner_id=owner_id, conversation_id=conversation_id)
        if conversation is None:
            return None
        await self.repository.mark_stale_runs_failed(
            owner_id=owner_id,
            conversation_id=conversation_id,
            started_before=datetime.utcnow()
            - timedelta(seconds=stale_threshold_seconds(get_settings().chat_run_timeout_seconds)),
        )
        messages = await self.repository.list_messages(owner_id=owner_id, conversation_id=conversation_id)
        return ConversationSnapshot(conversation=conversation, messages=messages)


@dataclass(frozen=True, slots=True)
class DeleteConversation:
    """soft delete. 없거나 다른 owner 면 False (→ 404)."""

    repository: ConversationRepository

    async def execute(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        return await self.repository.soft_delete(owner_id=owner_id, conversation_id=conversation_id)


@dataclass(frozen=True, slots=True)
class SetProposalStatus:
    """proposal 카드 확정/취소 영속 — 스냅샷 복귀 시 카드 상태 복원의 단일 원천.

    confirmed/cancelled 만 영속한다 — expired(404)·failed 는 재확정 시 결정적으로
    재현되는 일시 상태라 저장할 가치가 없다. 없으면 False (→404).
    """

    repository: ConversationRepository

    async def execute(self, *, owner_id: UUID, conversation_id: UUID, proposal_id: UUID, status: str) -> bool:
        return await self.repository.set_proposal_status(
            owner_id=owner_id,
            conversation_id=conversation_id,
            proposal_id=proposal_id,
            status=status,
        )
