"""initial schema — captures, entities, embeddings, idempotency_keys, agent_runs, tool_calls + pgvector extension.

Revision ID: 0001
Revises:
Create Date: 2026-05-22 22:10:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        "captures",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("channel", sa.String(32), nullable=False),
        sa.Column("url", sa.String(2048)),
        sa.Column("text", sa.String),
        sa.Column("user_memo", sa.String),
        sa.Column("intent", sa.String(32), index=True),
        sa.Column("summary", sa.String),
        sa.Column("importance", sa.Integer, nullable=False, server_default="3"),
        sa.Column("confidence", sa.Float, nullable=False, server_default="0"),
        sa.Column("model_version", sa.String(64)),
        sa.Column("lifecycle_kind", sa.String(32), nullable=False, server_default="ingested", index=True),
        sa.Column("lifecycle_archive_reason", sa.String(32)),
        sa.Column("lifecycle_failure_reason", sa.String),
        sa.Column("sync_kind", sa.String(32), nullable=False, server_default="pending"),
        sa.Column("sync_detail", sa.String),
        sa.Column("captured_at", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )

    op.create_table(
        "entities",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("value", sa.String(512), nullable=False),
    )

    op.create_table(
        "embeddings",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("chunk_text", sa.String, nullable=False),
        sa.Column("embedding", Vector(768), nullable=False),
        sa.Column("model_version", sa.String(64), nullable=False),
    )
    op.execute(
        "CREATE INDEX ix_embeddings_vector_hnsw ON embeddings USING hnsw (embedding vector_cosine_ops) "
        "WITH (m = 16, ef_construction = 64)"
    )

    op.create_table(
        "idempotency_keys",
        sa.Column("key", sa.String(128), primary_key=True),
        sa.Column("capture_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )

    op.create_table(
        "agent_runs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("current_node", sa.String(32), nullable=False, server_default="ingested"),
        sa.Column("total_tokens", sa.Integer, nullable=False, server_default="0"),
        sa.Column("total_latency_ms", sa.Integer, nullable=False, server_default="0"),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("ended_at", sa.DateTime(timezone=True)),
        sa.Column("failure_reason", sa.String),
    )

    op.create_table(
        "tool_calls",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "agent_run_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("agent_runs.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("input_digest", sa.String(128), nullable=False),
        sa.Column("output_digest", sa.String(128)),
        sa.Column("tokens_in", sa.Integer, nullable=False, server_default="0"),
        sa.Column("tokens_out", sa.Integer, nullable=False, server_default="0"),
        sa.Column("latency_ms", sa.Integer, nullable=False, server_default="0"),
        sa.Column("succeeded", sa.Boolean, nullable=False, server_default=sa.text("true")),
        sa.Column("extra", postgresql.JSONB),
    )

    # 풀텍스트 검색용 GIN 인덱스 — BM25 근사 검색 가속.
    op.execute(
        "CREATE INDEX ix_captures_fts ON captures USING gin (to_tsvector('simple', coalesce(summary,'') || ' ' || coalesce(text,'')))"
    )


def downgrade() -> None:
    op.drop_index("ix_captures_fts", table_name="captures")
    op.drop_table("tool_calls")
    op.drop_table("agent_runs")
    op.drop_table("idempotency_keys")
    op.execute("DROP INDEX IF EXISTS ix_embeddings_vector_hnsw")
    op.drop_table("embeddings")
    op.drop_table("entities")
    op.drop_table("captures")
