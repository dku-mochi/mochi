"""llm_usage — LLM 토큰 사용량/비용 계측 테이블.

2026-06-13: Gemini 호출의 토큰 사용량을 관측한다. 기존 `agent_runs.total_tokens`/
`tool_calls.tokens_*` 는 값이 채워지지 않아 비용 분석이 불가했다. 모든 LLM 경로의
사용량을 단일 테이블에 모아(source 로 구분) 일별·사용자별·아이템별 토큰/비용을 SQL
한 번으로 집계한다. 모델명을 행마다 저장해 모델 변경 시에도 비용이 정확히 갈린다.

read-only 관측 테이블 — 4-Intent lifecycle/민감캡처/idempotency 어느 불변식도 건드리지 않는다.

Revision ID: 0021
Revises: 0020
Create Date: 2026-06-13 16:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0021"
down_revision: str | None = "0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "llm_usage",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        # 어느 LLM 경로인지: "capture"(아이템 분석 agent loop) | "chat"(채팅 run).
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        # capture 만 채움(아이템별 집계용). chat 은 NULL.
        sa.Column("mochi_item_id", postgresql.UUID(as_uuid=True), nullable=True),
        # chat 만 채움. capture 는 NULL.
        sa.Column("conversation_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("model", sa.String(64), nullable=False),
        sa.Column("tokens_in", sa.Integer, nullable=False, server_default="0"),
        sa.Column("tokens_out", sa.Integer, nullable=False, server_default="0"),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    # 일별 집계 + 사용자별 집계의 주 접근 경로.
    op.create_index("ix_llm_usage_created_at", "llm_usage", ["created_at"])
    op.create_index("ix_llm_usage_owner_id", "llm_usage", ["owner_id"])


def downgrade() -> None:
    op.drop_index("ix_llm_usage_owner_id", table_name="llm_usage")
    op.drop_index("ix_llm_usage_created_at", table_name="llm_usage")
    op.drop_table("llm_usage")
