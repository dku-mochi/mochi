"""conversations · messages · message_citations ORM — 마이그레이션 0016 과 1:1.

대화는 서버 단일원천(iOS Realm 미러 없음). run 영속은 트리거한 user message 행의
``run_id/run_status/run_started_at`` 3컬럼 — 별도 run 테이블 없음 (journal 2026-06-10).
"""

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import (
    UUID as PgUUIDColumn,  # noqa: N811 (Postgres UUID column constructor)
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base


class ConversationRow(Base):
    __tablename__ = "conversations"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    # 첫 user 메시지 truncate (LLM 요약 안 씀). 메시지 도착 전(이론상)엔 NULL 허용.
    title: Mapped[str | None] = mapped_column(String, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    # 마지막 메시지 시각 — 히스토리 시트 정렬 소스. add_message 가 bump 한다.
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    # soft delete (mochi_items 와 동일 패턴) — 모든 조회가 deleted_at IS NULL 로 가린다.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    # 부분 인덱스 ix_conversations_owner_updated (owner_id, updated_at WHERE deleted_at IS NULL)
    # 는 마이그레이션 0016 에서만 정의한다 — ix_mochi_items_active 와 동일 패턴.


class MessageRow(Base):
    __tablename__ = "messages"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    conversation_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("conversations.id", ondelete="CASCADE")
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    role: Mapped[str] = mapped_column(String(16))  # user | assistant | tool
    # user/assistant 텍스트. assistant 는 【item:id】 citation 마커 원문 보존.
    content: Mapped[str | None] = mapped_column(String, default=None)
    tool_name: Mapped[str | None] = mapped_column(String(64), default=None)
    tool_payload: Mapped[dict[str, Any] | None] = mapped_column(JSONB, default=None)
    # role=assistant 행의 proposal 카드 배열 (typed 스키마는 PR-3).
    proposals: Mapped[list[dict[str, Any]]] = mapped_column(
        JSONB, default_factory=list, server_default=text("'[]'::jsonb")
    )
    # role=user 행에만 — 이 발화가 트리거한 agent run.
    run_id: Mapped[UUID | None] = mapped_column(PgUUIDColumn(as_uuid=True), default=None)
    run_status: Mapped[str | None] = mapped_column(String(16), default=None)
    run_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)

    citations: Mapped[list["MessageCitationRow"]] = relationship(
        back_populates="message", cascade="all, delete-orphan", default_factory=list
    )

    __table_args__ = (Index("ix_messages_conversation_created", "conversation_id", "created_at"),)


class MessageCitationRow(Base):
    __tablename__ = "message_citations"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    message_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("messages.id", ondelete="CASCADE"), init=False
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    # FK 없음 — item 삭제 후에도 "그때 무엇을 근거로 답했나" 스냅샷(title/snippet) 보존.
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    citation_index: Mapped[int] = mapped_column(Integer)
    title: Mapped[str | None] = mapped_column(String, default=None)
    snippet: Mapped[str | None] = mapped_column(String, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)

    message: Mapped["MessageRow"] = relationship(back_populates="citations", default=None)

    __table_args__ = (UniqueConstraint("message_id", "citation_index", name="ux_message_citation_index"),)
