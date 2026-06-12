from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from pgvector.sqlalchemy import Vector
from sqlalchemy import JSON, BigInteger, Boolean, DateTime, ForeignKey, Index, Integer, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import (
    UUID as PgUUIDColumn,  # noqa: N811 (Postgres UUID column constructor)
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base


class MochiItemRow(Base):
    __tablename__ = "mochi_items"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), index=True)
    channel: Mapped[str] = mapped_column(String(32))
    url: Mapped[str | None] = mapped_column(String(2048), default=None)
    text: Mapped[str | None] = mapped_column(String, default=None)
    user_memo: Mapped[str | None] = mapped_column(String, default=None)

    # 모찌가 분류를 확신 못 해 사용자에게 물을지 (LLM holistic boolean). 점수/threshold 폐기(2026-06-04).
    needs_review: Mapped[bool] = mapped_column(Boolean, default=False)
    # needs_review=true 일 때 제시할 미확정 후보. PR-B: transient→JSONB 컬럼 승격(헷갈려요 후보를
    # push payload·GET projection·앱 내 버킷 fallback 이 모두 읽는다). [{intent_type,label,reasoning}].
    review_options: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, default_factory=list)
    summary: Mapped[str | None] = mapped_column(String, default=None)
    category: Mapped[str | None] = mapped_column(String(64), default=None)
    # 주간 정리(digest)가 category 를 정규화(refetch)한 시각. NULL 이면 아직 raw fine —
    # digest 의 known_categories(연쇄 톤앤매너) 컨텍스트에서 제외해, 정규화된 라벨만 다음 주로 잇는다.
    category_normalized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    importance: Mapped[int] = mapped_column(Integer, default=3)
    model_version: Mapped[str | None] = mapped_column(String(64), default=None)

    # 처리상태(ingested/analyzing/analyzed/failed) — 의미 lifecycle(archive_reason)은 intent_instances 로 이동.
    lifecycle_kind: Mapped[str] = mapped_column(String(32), default="ingested", index=True)
    lifecycle_failure_reason: Mapped[str | None] = mapped_column(String, default=None)

    sync_kind: Mapped[str] = mapped_column(String(32), default="pending")
    sync_detail: Mapped[str | None] = mapped_column(String, default=None)

    captured_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default_factory=datetime.utcnow, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)

    # soft delete — 사용자 삭제 시 행을 지우지 않고 마킹(되돌릴 수 있게, users 와 동일 패턴).
    # 모든 조회는 deleted_at IS NULL 로 가린다.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    intent_instances: Mapped[list["IntentInstanceRow"]] = relationship(
        back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list
    )
    entities: Mapped[list["EntityRow"]] = relationship(
        back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list
    )
    embeddings: Mapped[list["EmbeddingRow"]] = relationship(
        back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list
    )
    image_refs: Mapped[list["MochiItemImageRefRow"]] = relationship(
        back_populates="mochi_item", cascade="all, delete-orphan", default_factory=list
    )


class MochiItemImageRefRow(Base):
    __tablename__ = "mochi_item_image_refs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True, init=False
    )
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    mime_type: Mapped[str] = mapped_column(String(64))
    byte_size: Mapped[int] = mapped_column(BigInteger)
    object_key: Mapped[str | None] = mapped_column(String(512), default=None)
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="image_refs", default=None)


class IntentInstanceRow(Base):
    """LLM 이 한 캡쳐에서 펼친 의도 1개 — 1급 행. 저장돼 있으면 곧 active.

    위계 없음(같은 ``intent_type`` 다중 허용). ``lifecycle_kind`` 는 instance 단위 의미상태
    (active/decaying/reviewRequested/archived) — item 처리상태(``mochi_items.lifecycle_kind``)와 직교.
    """

    __tablename__ = "intent_instances"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    mochi_item_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True, init=False
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True))
    intent_type: Mapped[str] = mapped_column(String(16))
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, default_factory=dict)
    label: Mapped[str | None] = mapped_column(String(255), default=None)
    reasoning: Mapped[str | None] = mapped_column(String, default=None)
    lifecycle_kind: Mapped[str] = mapped_column(String(32), default="active")
    lifecycle_archive_reason: Mapped[str | None] = mapped_column(String(32), default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="intent_instances", default=None)

    __table_args__ = (
        # "owner 의 미완 todo 만" 같은 instance 필터 — intent_type + lifecycle 복합 (owner_id leftmost).
        Index("ix_intent_instances_owner_type_lc", "owner_id", "intent_type", "lifecycle_kind"),
    )


class EntityRow(Base):
    __tablename__ = "entities"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True
    )
    kind: Mapped[str] = mapped_column(String(16))
    value: Mapped[str] = mapped_column(String(512))
    mochi_item: Mapped["MochiItemRow"] = relationship(back_populates="entities", default=None)


class EmbeddingRow(Base):
    __tablename__ = "embeddings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    mochi_item_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True
    )
    chunk_text: Mapped[str] = mapped_column(String)
    # voyage-3-large @ 1024 (rag-rerank-eval 확정, 마이그레이션 0018). 차원 변경은
    # HNSW drop → ALTER TYPE → 재색인이 한 묶음 — settings 만 바꿔서는 안 된다.
    embedding: Mapped[list[float]] = mapped_column(Vector(1024))
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

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    mochi_item_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="CASCADE"), index=True
    )
    current_node: Mapped[str] = mapped_column(String(32), default="ingested")
    total_tokens: Mapped[int] = mapped_column(Integer, default=0)
    total_latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    failure_reason: Mapped[str | None] = mapped_column(String, default=None)


class ToolCallRow(Base):
    __tablename__ = "tool_calls"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    agent_run_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("agent_runs.id", ondelete="CASCADE"), index=True
    )
    name: Mapped[str] = mapped_column(String(64))
    input_digest: Mapped[str] = mapped_column(String(128))
    output_digest: Mapped[str | None] = mapped_column(String(128), default=None)
    tokens_in: Mapped[int] = mapped_column(Integer, default=0)
    tokens_out: Mapped[int] = mapped_column(Integer, default=0)
    latency_ms: Mapped[int] = mapped_column(Integer, default=0)
    succeeded: Mapped[bool] = mapped_column(default=True)
    extra: Mapped[dict[str, Any] | None] = mapped_column(JSON, default=None)
