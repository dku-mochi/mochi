"""device_push_tokens — 단말/Live Activity push 토큰 (PR-B APNs).

2026-06-05 PR-B: background/종료 분석완료 통지를 위한 APNs push 토큰 저장.
owner 1:N 단말(apns_device) + mochi_item 1:1 Live Activity(live_activity)를 token_type 으로 구분.
environment 컬럼으로 sandbox/production device token 라우팅(BadDeviceToken 회피).

Revision ID: 0011
Revises: 0010
Create Date: 2026-06-05 11:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "device_push_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "owner_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("token_type", sa.String(16), nullable=False),
        sa.Column(
            "mochi_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("mochi_items.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("environment", sa.String(16), nullable=False, server_default="sandbox"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("ix_device_push_tokens_owner_id", "device_push_tokens", ["owner_id"])
    # token globally unique — apns_device 는 폰 단위라 계정 전환 시 owner 갱신(cross-account push 차단),
    # LA 는 item별 고유. device/LA 토큰은 형식이 달라 충돌하지 않는다.
    op.create_index(
        "ux_device_push_tokens_token",
        "device_push_tokens",
        ["token"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("ux_device_push_tokens_token", table_name="device_push_tokens")
    op.drop_index("ix_device_push_tokens_owner_id", table_name="device_push_tokens")
    op.drop_table("device_push_tokens")
