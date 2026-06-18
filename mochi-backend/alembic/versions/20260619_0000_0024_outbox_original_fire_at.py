"""notification_outbox.original_fire_at — 사용자 reschedule 시 모찌 원안 fire_at 보존.

홈탭 "예정 알림"에서 사용자가 pending 알림의 발송 시각을 옮기면(reschedule), 첫 조정 때만
원래 fire_at 을 COALESCE 로 1회 보존한다(되돌리기·원안 표시·분석용). NULL = 미조정(현 fire_at=원안).
worker(notification_worker)는 이 컬럼을 읽지 않는다 — fire_at 직접 갱신의 무변경 불변식 유지.

Revision ID: 0024
Revises: 0023
Create Date: 2026-06-19 00:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0024"
down_revision: str | None = "0023"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "notification_outbox",
        sa.Column("original_fire_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("notification_outbox", "original_fire_at")
