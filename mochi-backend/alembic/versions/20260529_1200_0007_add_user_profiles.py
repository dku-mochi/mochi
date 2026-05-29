"""add user_profiles table — 사용자 개인화 프로필 (sliding-window 특성 요약).

agent loop 가 분석 시 주입하는 유저별 "관심사·분류 성향" 요약을 보관한다.
owner_id 당 1행. 본문은 추상 요약만 저장(raw 콘텐츠 미보관 — 프라이버시).

Revision ID: 0007
Revises: 0006
Create Date: 2026-05-29 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_profiles",
        sa.Column("owner_id", UUID(as_uuid=True), primary_key=True),
        sa.Column("summary", sa.String(), nullable=False),
        sa.Column("model_version", sa.String(length=64), nullable=False),
        sa.Column("items_covered", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("refreshed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )


def downgrade() -> None:
    op.drop_table("user_profiles")
