"""mochi_items_soft_delete — 기록 soft delete.

2026-06-08: 기록 상세에서 사용자가 mochi_item 을 삭제할 수 있도록 ``deleted_at`` 마킹 컬럼 추가.
행을 물리 삭제하지 않고 마킹만 하며(users 와 동일 패턴, 되돌릴 수 있게), 모든 조회 쿼리가
``deleted_at IS NULL`` 로 가린다. 부분 인덱스(active 행만)로 owner 조회를 가볍게 유지한다.

Revision ID: 0013
Revises: 0012
Create Date: 2026-06-08 22:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_items",
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    # 살아있는 행(deleted_at IS NULL)만 인덱싱 — owner 조회는 거의 항상 active 행 대상이라
    # 삭제 마킹된 행이 인덱스를 부풀리지 않게 한다.
    op.create_index(
        "ix_mochi_items_active",
        "mochi_items",
        ["owner_id"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_mochi_items_active", table_name="mochi_items")
    op.drop_column("mochi_items", "deleted_at")
