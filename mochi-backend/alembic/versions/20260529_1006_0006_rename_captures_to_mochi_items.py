"""rename captures → mochi_items: 테이블 3개 + FK 컬럼 capture_id → mochi_item_id + FTS 인덱스.

`capture` = 이미지 캡처 행위, `mochi_item` = URL+이미지+링크 통합 도메인 객체로 의미 분리.
코드 식별자/모듈은 B1·B2 에서 이미 갱신됨. 이 마이그레이션이 DB 스키마를 그에 맞춘다.

- 테이블: captures → mochi_items, capture_image_refs → mochi_item_image_refs,
  capture_outbox → mochi_item_outbox
- FK 컬럼: 6개 테이블의 capture_id → mochi_item_id
- 인덱스: ix_captures_fts → ix_mochi_items_fts (BM25 GIN)

Revision ID: 0006
Revises: 0005
Create Date: 2026-05-29 10:06:00.000000
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_FK_TABLES = [
    "entities",
    "embeddings",
    "idempotency_keys",
    "agent_runs",
    "mochi_item_outbox",
    "mochi_item_image_refs",
]


def upgrade() -> None:
    op.rename_table("captures", "mochi_items")
    op.rename_table("capture_image_refs", "mochi_item_image_refs")
    op.rename_table("capture_outbox", "mochi_item_outbox")

    for table in _FK_TABLES:
        op.alter_column(table, "capture_id", new_column_name="mochi_item_id")

    op.execute("ALTER INDEX ix_captures_fts RENAME TO ix_mochi_items_fts")


def downgrade() -> None:
    op.execute("ALTER INDEX ix_mochi_items_fts RENAME TO ix_captures_fts")

    for table in _FK_TABLES:
        op.alter_column(table, "mochi_item_id", new_column_name="capture_id")

    op.rename_table("mochi_item_outbox", "capture_outbox")
    op.rename_table("mochi_item_image_refs", "capture_image_refs")
    op.rename_table("mochi_items", "captures")
