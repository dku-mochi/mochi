"""conversations — 채팅(질문 탭) 멀티턴 대화 영속.

2026-06-10: 채팅 탭 설계 확정(journal 2026-06-10-chat-tab-design.md)으로 DOMAIN_DESIGN §10.3
design-ahead 게이트 개방. 3테이블:

- ``conversations`` — 세션. soft delete(deleted_at), 히스토리 정렬은 updated_at(마지막 메시지 시각).
- ``messages`` — user/assistant/tool 행. run 영속은 별도 테이블 없이 트리거한 user 행의
  ``run_id/run_status/run_started_at`` (stale 은 스냅샷 읽기 시점 lazy repair).
- ``message_citations`` — 답변 출처 스냅샷. ``mochi_item_id`` 에 FK 를 걸지 않는다 —
  item 삭제 후에도 "그때 무엇을 근거로 답했나"(title/snippet)를 보존.

Revision ID: 0016
Revises: 0015
Create Date: 2026-06-10 21:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

from alembic import op

revision: str = "0016"
down_revision: str | None = "0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "conversations",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_id", UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    # 히스토리 시트 = owner 의 살아있는 대화 updated_at desc — active 행만 부분 인덱스
    # (ix_mochi_items_active 와 동일 패턴).
    op.create_index(
        "ix_conversations_owner_updated",
        "conversations",
        ["owner_id", "updated_at"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "messages",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "conversation_id",
            UUID(as_uuid=True),
            sa.ForeignKey("conversations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("owner_id", UUID(as_uuid=True), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("content", sa.String(), nullable=True),
        sa.Column("tool_name", sa.String(length=64), nullable=True),
        sa.Column("tool_payload", JSONB(), nullable=True),
        sa.Column("proposals", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("run_id", UUID(as_uuid=True), nullable=True),
        sa.Column("run_status", sa.String(length=16), nullable=True),
        sa.Column("run_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_messages_conversation_created", "messages", ["conversation_id", "created_at"])

    op.create_table(
        "message_citations",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "message_id",
            UUID(as_uuid=True),
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("owner_id", UUID(as_uuid=True), nullable=False),
        sa.Column("mochi_item_id", UUID(as_uuid=True), nullable=False),
        sa.Column("citation_index", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(), nullable=True),
        sa.Column("snippet", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", "citation_index", name="ux_message_citation_index"),
    )


def downgrade() -> None:
    op.drop_table("message_citations")
    op.drop_index("ix_messages_conversation_created", table_name="messages")
    op.drop_table("messages")
    op.drop_index("ix_conversations_owner_updated", table_name="conversations")
    op.drop_table("conversations")
