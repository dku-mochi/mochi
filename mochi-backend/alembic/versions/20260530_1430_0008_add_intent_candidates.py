"""mochi_items: intent_candidates (jsonb) — LLM use case 후보 영속.

worker 단일 분석 경로 전환(2026-05-30): agent 의 ``finalizeAnalysis`` 가 펼친 후보
``[{label, intent, applicability, reasoning}]`` 를 영속한다. 홈 "헷갈려요" 카드·Live
Activity 버튼의 원천이며, confidence/multi-intent 판정의 applicability 단일 원천.
(동기 back-tap 분류 경로 제거에 동반 — 후보는 이제 worker 가 비동기로 채운다.)

Revision ID: 0008
Revises: 0007
Create Date: 2026-05-30 14:30:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "mochi_items",
        sa.Column(
            "intent_candidates",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
    )


def downgrade() -> None:
    op.drop_column("mochi_items", "intent_candidates")
