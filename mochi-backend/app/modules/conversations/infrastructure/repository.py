"""SQLAlchemy 기반 ``ConversationRepository`` 구현."""

from datetime import datetime
from typing import Any, cast
from uuid import UUID

from sqlalchemy import CursorResult, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.modules.conversations.domain.entities import (
    Conversation,
    Message,
    MessageCitation,
    MessageRole,
    RunStatus,
)
from app.modules.conversations.domain.ports import ConversationRepository as ConversationRepositoryPort
from app.modules.conversations.infrastructure.orm import (
    ConversationRow,
    MessageCitationRow,
    MessageRow,
)


def _to_conversation(row: ConversationRow) -> Conversation:
    return Conversation(
        id=row.id,
        title=row.title,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _to_message(row: MessageRow) -> Message:
    return Message(
        id=row.id,
        conversation_id=row.conversation_id,
        role=MessageRole(row.role),
        content=row.content,
        tool_name=row.tool_name,
        tool_payload=row.tool_payload,
        proposals=tuple(row.proposals or ()),
        run_id=row.run_id,
        run_status=RunStatus(row.run_status) if row.run_status else None,
        run_started_at=row.run_started_at,
        citations=tuple(
            MessageCitation(
                id=c.id,
                mochi_item_id=c.mochi_item_id,
                citation_index=c.citation_index,
                title=c.title,
                snippet=c.snippet,
            )
            for c in sorted(row.citations, key=lambda c: c.citation_index)
        ),
        created_at=row.created_at,
    )


def merge_proposal_status(
    proposals: list[dict[str, Any]], proposal_id: str, status: str
) -> list[dict[str, Any]] | None:
    """proposals jsonb 에서 ``proposal_id`` entry 에 status 를 병합한 새 리스트.
    해당 entry 가 없으면 None — 순수 함수로 분리해 jsonb 병합 로직을 단위테스트한다."""
    for index, entry in enumerate(proposals):
        if isinstance(entry, dict) and entry.get("id") == proposal_id:
            updated = list(proposals)
            updated[index] = {**entry, "status": status}
            return updated
    return None


class PostgresConversationRepository(ConversationRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create(self, *, owner_id: UUID, conversation: Conversation) -> None:
        row = ConversationRow(
            owner_id=owner_id,
            title=conversation.title,
            created_at=conversation.created_at,
            updated_at=conversation.updated_at,
        )
        row.id = conversation.id
        self._session.add(row)
        await self._session.flush()

    async def find_by_id(self, *, owner_id: UUID, conversation_id: UUID) -> Conversation | None:
        row = await self._session.scalar(
            select(ConversationRow).where(
                ConversationRow.id == conversation_id,
                ConversationRow.owner_id == owner_id,
                ConversationRow.deleted_at.is_(None),
            )
        )
        return _to_conversation(row) if row else None

    async def list_for_owner(self, *, owner_id: UUID, limit: int) -> list[Conversation]:
        rows = await self._session.scalars(
            select(ConversationRow)
            .where(
                ConversationRow.owner_id == owner_id,
                ConversationRow.deleted_at.is_(None),
            )
            .order_by(ConversationRow.updated_at.desc())
            .limit(limit)
        )
        return [_to_conversation(r) for r in rows.all()]

    async def soft_delete(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        result = cast(
            CursorResult[Any],
            await self._session.execute(
                update(ConversationRow)
                .where(
                    ConversationRow.id == conversation_id,
                    ConversationRow.owner_id == owner_id,
                    ConversationRow.deleted_at.is_(None),
                )
                .values(deleted_at=datetime.utcnow())
            ),
        )
        await self._session.flush()
        return (result.rowcount or 0) > 0

    async def add_message(self, *, owner_id: UUID, message: Message) -> bool:
        # bump 가 곧 소유·생존 검증 — owner 불일치·soft delete·미존재 대화면 0행이라
        # 메시지를 넣지 않고 False (cross-tenant 쓰기·고아 행 차단). greatest 는 동시
        # add_message 의 늦은 commit 이 updated_at 을 과거로 되돌리는 것을 막는다.
        result = cast(
            CursorResult[Any],
            await self._session.execute(
                update(ConversationRow)
                .where(
                    ConversationRow.id == message.conversation_id,
                    ConversationRow.owner_id == owner_id,
                    ConversationRow.deleted_at.is_(None),
                )
                .values(updated_at=func.greatest(ConversationRow.updated_at, message.created_at))
            ),
        )
        if (result.rowcount or 0) == 0:
            return False
        row = MessageRow(
            conversation_id=message.conversation_id,
            owner_id=owner_id,
            role=message.role.value,
            content=message.content,
            tool_name=message.tool_name,
            tool_payload=message.tool_payload,
            proposals=list(message.proposals),
            run_id=message.run_id,
            run_status=message.run_status.value if message.run_status else None,
            run_started_at=message.run_started_at,
            created_at=message.created_at,
        )
        row.id = message.id
        for citation in message.citations:
            citation_row = MessageCitationRow(
                owner_id=owner_id,
                mochi_item_id=citation.mochi_item_id,
                citation_index=citation.citation_index,
                title=citation.title,
                snippet=citation.snippet,
            )
            citation_row.id = citation.id
            row.citations.append(citation_row)
        self._session.add(row)
        await self._session.flush()
        return True

    async def list_messages(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        rows = await self._session.scalars(
            select(MessageRow)
            .options(selectinload(MessageRow.citations))
            .where(
                MessageRow.conversation_id == conversation_id,
                MessageRow.owner_id == owner_id,
            )
            .order_by(MessageRow.created_at.asc())
        )
        return [_to_message(r) for r in rows.all()]

    async def has_running_run(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        row = await self._session.scalar(
            select(MessageRow.id)
            .where(
                MessageRow.conversation_id == conversation_id,
                MessageRow.owner_id == owner_id,
                MessageRow.run_status == RunStatus.RUNNING.value,
            )
            .limit(1)
        )
        return row is not None

    async def set_run_status(self, *, owner_id: UUID, run_id: UUID, status: RunStatus) -> bool:
        result = cast(
            CursorResult[Any],
            await self._session.execute(
                update(MessageRow)
                .where(
                    MessageRow.run_id == run_id,
                    MessageRow.owner_id == owner_id,
                    # run 상태는 트리거한 user 행에만 — tool/assistant 행도 같은 run_id 를 가진다.
                    MessageRow.role == MessageRole.USER.value,
                )
                .values(run_status=status.value)
            ),
        )
        await self._session.flush()
        return (result.rowcount or 0) > 0

    async def set_proposal_status(
        self, *, owner_id: UUID, conversation_id: UUID, proposal_id: UUID, status: str
    ) -> bool:
        # 대화의 assistant 행을 훑어 Python 에서 병합 — 세션 자동분리(30분)라 행 수가 작고,
        # jsonb path 연산을 피해 단순함을 산다.
        rows = await self._session.scalars(
            select(MessageRow).where(
                MessageRow.conversation_id == conversation_id,
                MessageRow.owner_id == owner_id,
                MessageRow.role == MessageRole.ASSISTANT.value,
            )
        )
        target = str(proposal_id)
        for row in rows.all():
            updated = merge_proposal_status(list(row.proposals or []), target, status)
            if updated is not None:
                row.proposals = updated
                await self._session.flush()
                return True
        return False

    async def mark_stale_runs_failed(
        self, *, owner_id: UUID, conversation_id: UUID, started_before: datetime
    ) -> int:
        result = cast(
            CursorResult[Any],
            await self._session.execute(
                update(MessageRow)
                .where(
                    MessageRow.conversation_id == conversation_id,
                    MessageRow.owner_id == owner_id,
                    MessageRow.run_status == RunStatus.RUNNING.value,
                    MessageRow.run_started_at < started_before,
                )
                .values(run_status=RunStatus.FAILED.value)
            ),
        )
        await self._session.flush()
        return result.rowcount or 0
