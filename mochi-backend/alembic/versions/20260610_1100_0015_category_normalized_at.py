"""add mochi item category_normalized_at

주간 정리(digest)가 category 를 정규화한 시각 마커. NULL=raw fine(아직 미정규화).
digest 의 known_categories(연쇄 톤앤매너) 가 정규화된 라벨만 다음 주로 잇기 위함.

Revision ID: 0015
Revises: 0014
Create Date: 2026-06-10 11:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0015"
down_revision: str | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_items",
        sa.Column("category_normalized_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("mochi_items", "category_normalized_at")
