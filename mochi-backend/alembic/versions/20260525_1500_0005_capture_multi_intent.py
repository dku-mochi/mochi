"""capture multi-intent: intent NOT NULL + secondary_intents (text[]) + intent_applicability (jsonb).

2026-05-25 실험 (`_workspace/2026-05-25-intent-classification-bench.md`) 결과로 사용자가 한
캡쳐에 여러 의도를 동시에 갖는 게 default 패턴 (13/13 multi) 임이 확정. 이를 도메인에
표현하기 위해 captures 테이블 확장:

- ``intent`` 를 NOT NULL 로 강화. 분류 전 일반 ingestion 경로의 default 는 ``'memo'``
  (`Capture` 엔티티 default 와 일치 — 정서적·일회적 기록).
- ``secondary_intents`` (text[]): applicability 내림차순의 보조 의도. primary 와 중복 없음.
- ``intent_applicability`` (jsonb): Intent value (`'todo'` 등) → 0.0–1.0 적용 강도.
  후보에 등장하지 않은 intent 는 키에 포함되지 않는다.

Revision ID: 0005
Revises: 0004
Create Date: 2026-05-25 15:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "captures",
        "intent",
        existing_type=sa.String(32),
        nullable=False,
        server_default="memo",
    )
    op.add_column(
        "captures",
        sa.Column(
            "secondary_intents",
            postgresql.ARRAY(sa.String(32)),
            nullable=False,
            server_default=sa.text("ARRAY[]::varchar[]"),
        ),
    )
    op.add_column(
        "captures",
        sa.Column(
            "intent_applicability",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )


def downgrade() -> None:
    op.drop_column("captures", "intent_applicability")
    op.drop_column("captures", "secondary_intents")
    op.alter_column(
        "captures",
        "intent",
        existing_type=sa.String(32),
        nullable=True,
        server_default=None,
    )
