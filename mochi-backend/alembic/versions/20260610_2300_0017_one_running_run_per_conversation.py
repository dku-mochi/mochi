"""messages — 대화당 진행 중 run 1개 강제 (partial unique index).

2026-06-10 리뷰 P2: ``BeginChatTurn`` 의 has_running_run 검사는 트랜잭션 격리로 동시
POST 2건이 모두 통과할 수 있다(TOCTOU). 애플리케이션 검사 대신 DB 가 레이스를 흡수 —
둘째 INSERT 가 IntegrityError 로 죽고 application 이 409 로 변환한다.

Revision ID: 0017
Revises: 0016
Create Date: 2026-06-10 23:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0017"
down_revision: str | None = "0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "ux_messages_one_running_per_conversation",
        "messages",
        ["conversation_id"],
        unique=True,
        postgresql_where=sa.text("run_status = 'running'"),
    )


def downgrade() -> None:
    op.drop_index("ux_messages_one_running_per_conversation", table_name="messages")
