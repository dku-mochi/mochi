from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from pgvector.sqlalchemy import Vector
from sqlalchemy import JSON, BigInteger, DateTime, Float, ForeignKey, Index, Integer, String
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.dialects.postgresql import (
    UUID as PgUUIDColumn,  # noqa: N811 (Postgres UUID column constructor)
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base
from app.shared.intent import Intent


class MochiItemRow(Base):
    __tablename__ = "mochi_items"

    id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False)
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), index=True)
    channel: Mapped[str] = mapped_column(String(32))
    url: Mapped[str | None] = mapped_column(String(2048), default=None)
    text: Mapped[str | None] = mapped_column(String, default=None)
    user_memo: Mapped[str | None] = mapped_column(String, default=None)

    intent: Mapped[str] = mapped_column(String(32), default=Intent.MEMO.value, index=True)
    secondary_intents: Mapped[list[str]] = mapped_column(
        ARRAY(String(32)), default_factory=list
    )
    intent_applicability: Mapped[dict[str, float]] = mapped_column(
        JSONB, default_factory=dict
    )
    summary: Mapped[str | None] = mapped_column(String, default=None)
    importance: Mapped[int] = mapped_column(Integer, default=3)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    model_version: Mapped[str | None] = mapped_column(String(64), default=None)

    lifecycle_kind: Mapped[str] = mapped_column(String(32), default="ingested", index=True)
    lifecycle_archive_reason: Mapped[str | None] = mapped_column(String(32), default=None)
    lifecycle_failure_reason: Mapped[str | None] = mapped_column(String, default=None)

    sync_kind: Mapped[str] = mapped_column(String(32), default="pending")
    sync_detail: Mapped[str | None] = mapped_column(String, default=None)

    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)

    entities: Mapped[list["EntityRow"]] = relationship(back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list)
    embeddings: Mapped[list["EmbeddingRow"]] = relationship(back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list)
    image_refs: Mapped[list["MochiItemImageRefRow"]] = relationship(back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list)


class MochiItemImageRefRow(Base):
    __tablename__ = "mochi_item_image_refs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True, init=False)
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    mime_type: Mapped[str] = mapped_column(String(64))
    byte_size: Mapped[int] = mapped_column(BigInteger)
    object_key: Mapped[str | None] = mapped_column(String(512), default=None)
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="image_refs", default=None)


class EntityRow(Base):
    __tablename__ = "entities"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(16))
    value: Mapped[str] = mapped_column(String(512))
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="entities", default=None)


class EmbeddingRow(Base):
    __tablename__ = "embeddings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True)
    chunk_text: Mapped[str] = mapped_column(String)
    embedding: Mapped[list[float]] = mapped_column(Vector(768))
    model_version: Mapped[str] = mapped_column(String(64))
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="embeddings", default=None)

    __table_args__ = (
        Index(
            "ix_embeddings_vector_hnsw",
            "embedding",
            postgresql_using="hnsw",
            postgresql_with={"m": 16, "ef_construction": 64},
            postgresql_ops={"embedding": "vector_cosine_ops"},
        ),
    )


class IdempotencyKeyRow(Base):
    __tablename__ = "idempotency_keys"

    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)


class AgentRunRow(Base):
    __tablename__ = "agent_runs"

    id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True)
    current_node: Mapped[str] = mapped_column(String(32), default="ingested")
    total_tokens: Mapped[int] = mapped_column(Integer, default=0)
    total_latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    failure_reason: Mapped[str | None] = mapped_column(String, default=None)


class ToolCallRow(Base):
    __tablename__ = "tool_calls"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    agent_run_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("agent_runs.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(64))
    input_digest: Mapped[str] = mapped_column(String(128))
    output_digest: Mapped[str | None] = mapped_column(String(128), default=None)
    tokens_in: Mapped[int] = mapped_column(Integer, default=0)
    tokens_out: Mapped[int] = mapped_column(Integer, default=0)
    latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    succeeded: Mapped[bool] = mapped_column(default=True)
    extra: Mapped[dict[str, Any] | None] = mapped_column(JSON, default=None)
