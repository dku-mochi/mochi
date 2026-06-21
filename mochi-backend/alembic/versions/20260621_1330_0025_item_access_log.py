"""item_access_log — 사용자 상세 열람 이벤트(append-only).

상세를 연 직전 화면(``source`` = navigation origin)과 시각을 1행으로 남긴다. 능동 회수
랭킹("최근 클릭한 기록" recency 가중 + "최근 본 건 소환 억제")의 데이터 원천. lifecycle 과
직교 — 상태 전이가 아니라 순수 관찰 로그라 같은 item 다회 열람 = 다회 행(멱등 아님).

``source`` 는 진화하는 분석 차원이라 DB CheckConstraint 로 굳히지 않는다(API enum 으로만 검증) —
origin 추가가 마이그레이션을 요구하지 않게. ``owner_id`` 는 기존 컨벤션대로 FK 없이 denormalized.

Revision ID: 0025
Revises: 0024
Create Date: 2026-06-21 13:30:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0025"
down_revision: str | None = "0024"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "item_access_log",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "mochi_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("mochi_items.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("accessed_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    # 최근 N일 클릭 윈도우(owner 단위 시계열 스캔).
    op.create_index("ix_item_access_log_owner_accessed", "item_access_log", ["owner_id", "accessed_at"])
    # per-item 마지막 접근 / 소생 억제(특정 item 의 최근 열람 여부).
    op.create_index(
        "ix_item_access_log_owner_item_accessed",
        "item_access_log",
        ["owner_id", "mochi_item_id", "accessed_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_item_access_log_owner_item_accessed", table_name="item_access_log")
    op.drop_index("ix_item_access_log_owner_accessed", table_name="item_access_log")
    op.drop_table("item_access_log")
