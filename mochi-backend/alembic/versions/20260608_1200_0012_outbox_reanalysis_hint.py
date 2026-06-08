"""outbox_reanalysis_hint — "다른 의도" 재분석 힌트 (transient).

2026-06-08: needs_review 항목에서 사용자가 "다른 의도"로 재분석을 요청할 때 적은 의도 힌트를
분석 프롬프트 context 에만 합류시키기 위한 컬럼. outbox 행에 일시 적재되어 worker 가 분석에
쓰고 행과 함께 소멸한다 — ``mochi_items``/``user_memo`` 에는 저장하지 않는다(사용자가 직접 쓴
메모로 오해하는 것을 막는다).

Revision ID: 0012
Revises: 0011
Create Date: 2026-06-08 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_item_outbox",
        sa.Column("reanalysis_hint", sa.String(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("mochi_item_outbox", "reanalysis_hint")
