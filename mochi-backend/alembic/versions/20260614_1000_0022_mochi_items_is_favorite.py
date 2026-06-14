"""mochi_items.is_favorite — 사용자 "중요" 즐겨찾기 신호.

분석결과가 아니라 사용자 가변 상태다(category/importance 처럼 item 레벨 인라인). 사용자가 검색 카드·
상세에서 토글하면 모찌가 능동 회수(홈 즐겨찾기 시트)에 활용한다. reanalyze 는 건드리지 않는다.
NOT NULL DEFAULT false — 기존 행은 전부 비즐겨찾기로 백필.

Revision ID: 0022
Revises: 0021
Create Date: 2026-06-14 10:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0022"
down_revision: str | None = "0021"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_items",
        sa.Column("is_favorite", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("mochi_items", "is_favorite")
