"""embeddings — text-embedding-005(768) → voyage-4-large(1024).

임베딩 모델 선정: ``lab/archive/rag-search`` (voyage-4-large@1024). 리랭커: ``lab/archive/rag-rerank-eval``
(2026-06-12) rerank-2.5. 컬럼은 1024차원 고정이라 모델과 무관 — 이 마이그레이션의 DDL 은 동일하다.
기존 행은 EmbedTool 이 wire 되기 전의 zero-vector placeholder 뿐이라 TRUNCATE 가
데이터 손실이 아니다. 재색인은 신규 ingestion(INDEXED 노드) + 기존분
``scripts/backfill_embeddings.py`` 가 담당한다.

HNSW 인덱스는 차원이 고정된 타입 위에 만들어지므로 ALTER TYPE 전에 drop 해야 한다.

Revision ID: 0018
Revises: 0017
Create Date: 2026-06-12 14:00:00.000000
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0018"
down_revision: str | None = "0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_HNSW = dict(
    postgresql_using="hnsw",
    postgresql_with={"m": 16, "ef_construction": 64},
    postgresql_ops={"embedding": "vector_cosine_ops"},
)


def upgrade() -> None:
    op.drop_index("ix_embeddings_vector_hnsw", table_name="embeddings")
    op.execute("TRUNCATE embeddings")
    op.execute("ALTER TABLE embeddings ALTER COLUMN embedding TYPE vector(1024)")
    op.create_index("ix_embeddings_vector_hnsw", "embeddings", ["embedding"], **_HNSW)


def downgrade() -> None:
    op.drop_index("ix_embeddings_vector_hnsw", table_name="embeddings")
    op.execute("TRUNCATE embeddings")
    op.execute("ALTER TABLE embeddings ALTER COLUMN embedding TYPE vector(768)")
    op.create_index("ix_embeddings_vector_hnsw", "embeddings", ["embedding"], **_HNSW)
