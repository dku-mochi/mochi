"""users.notify_recall_enabled / notify_analysis_enabled — 알림 전역 선호.

회수 푸시(트랙 A/B/C)와 분석 확인(needs_review) 알림의 사용자별 on/off 밸브.
발송 시점 게이트만 바꾼다 — plan 생성·outbox 적재·인앱 표면은 불변이라 다시 켜면
다음 fire_at 부터 재개된다. NOT NULL DEFAULT true — 기존 행은 전부 on 으로 백필
(0022 is_favorite 와 동일 인라인 컬럼 패턴).

Revision ID: 0028
Revises: 0027
Create Date: 2026-07-14 15:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0028"
down_revision: str | None = "0027"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("notify_recall_enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.add_column(
        "users",
        sa.Column("notify_analysis_enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
    )


def downgrade() -> None:
    op.drop_column("users", "notify_analysis_enabled")
    op.drop_column("users", "notify_recall_enabled")
