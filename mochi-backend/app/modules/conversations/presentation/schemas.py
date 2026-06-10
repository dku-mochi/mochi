"""/conversations DTO — iOS 채팅 탭(히스토리 시트·스냅샷 재조회)과 1:1."""

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field

from app.modules.conversations.domain.entities import (
    Conversation,
    Message,
    MessageCitation,
)


class ConversationResponse(BaseModel):
    id: UUID
    title: str | None = None
    created_at: datetime = Field(alias="createdAt")
    updated_at: datetime = Field(alias="updatedAt")

    model_config = {"populate_by_name": True}

    @classmethod
    def from_entity(cls, conversation: Conversation) -> "ConversationResponse":
        return cls(
            id=conversation.id,
            title=conversation.title,
            created_at=conversation.created_at,
            updated_at=conversation.updated_at,
        )


class ConversationListResponse(BaseModel):
    conversations: list[ConversationResponse] = Field(default_factory=list)


class MessageCitationResponse(BaseModel):
    mochi_item_id: UUID = Field(alias="mochiItemId")
    index: int
    title: str | None = None
    snippet: str | None = None

    model_config = {"populate_by_name": True}

    @classmethod
    def from_entity(cls, citation: MessageCitation) -> "MessageCitationResponse":
        return cls(
            mochi_item_id=citation.mochi_item_id,
            index=citation.citation_index,
            title=citation.title,
            snippet=citation.snippet,
        )


class MessageResponse(BaseModel):
    id: UUID
    role: str
    # assistant content 는 【item:id】 citation 마커 원문 — iOS 가 SSE 때와 동일하게 치환 렌더.
    content: str | None = None
    tool_name: str | None = Field(default=None, alias="toolName")
    tool_payload: dict[str, Any] | None = Field(default=None, alias="toolPayload")
    proposals: list[dict[str, Any]] = Field(default_factory=list)
    run_id: UUID | None = Field(default=None, alias="runId")
    run_status: str | None = Field(default=None, alias="runStatus")
    citations: list[MessageCitationResponse] = Field(default_factory=list)
    created_at: datetime = Field(alias="createdAt")

    model_config = {"populate_by_name": True}

    @classmethod
    def from_entity(cls, message: Message) -> "MessageResponse":
        return cls(
            id=message.id,
            role=message.role.value,
            content=message.content,
            tool_name=message.tool_name,
            tool_payload=message.tool_payload,
            proposals=list(message.proposals),
            run_id=message.run_id,
            run_status=message.run_status.value if message.run_status else None,
            citations=[MessageCitationResponse.from_entity(c) for c in message.citations],
            created_at=message.created_at,
        )


class ConversationSnapshotResponse(BaseModel):
    """대화 메시지 전체 스냅샷 — 포그라운드 복귀·히스토리 재진입의 단일 데이터 소스."""

    conversation: ConversationResponse
    messages: list[MessageResponse] = Field(default_factory=list)
