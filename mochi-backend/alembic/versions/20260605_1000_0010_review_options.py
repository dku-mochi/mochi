"""mochi_items.review_options JSONB 컬럼 — 헷갈려요 후보 영속화 (PR-B 컬럼 승격).

2026-06-05 PR-B: review_options 는 transient(가드레일 2)였으나, 헷갈려요 후보를 push payload·
GET projection·앱 내 needsReview 버킷 fallback 이 모두 읽어야 해 JSONB 컬럼으로 승격한다.
prod 아님 — 실데이터 폐기 허용, backfill 없음(기존 row 는 server_default '[]' 로 채워짐).

Revision ID: 0010
Revises: 0009
Create Date: 2026-06-05 10:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_items",
        sa.Column(
            "review_options",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
    )


def downgrade() -> None:
    op.drop_column("mochi_items", "review_options")
