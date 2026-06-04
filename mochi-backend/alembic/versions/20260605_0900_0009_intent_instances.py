"""intent 스키마 빅뱅: intent_instances 테이블 신설 + needs_review, mochi_items intent 5컬럼 DROP.

2026-06-04 빅뱅(lab FINDINGS): boolean instance 모델이 score_flat(applicability+threshold)을
intent F1 0.809→0.935 로 이겼다. intent 저장을 ``mochi_items`` 5컬럼 파생중복 → 별도
``intent_instances`` 테이블(1급 행, instance 단위 lifecycle)로 교체. 점수/대표/위계 폐기.

prod 아님 — 실데이터 폐기 허용, backfill 없음. ``mochi_items.lifecycle_kind`` 의 의미는
"분석 파이프라인 상태"(ingested/analyzing/analyzed/failed)로 축소되나, 옛 row 가 없어
값 backfill(active→analyzed)도 불필요하다.

Revision ID: 0009
Revises: 0008
Create Date: 2026-06-05 09:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # 1) intent_instances — 1급 행 (instance 단위 의미 lifecycle)
    op.create_table(
        "intent_instances",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "mochi_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("mochi_items.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("intent_type", sa.String(16), nullable=False),
        sa.Column("payload", postgresql.JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("label", sa.String(255)),
        sa.Column("reasoning", sa.Text()),
        sa.Column("lifecycle_kind", sa.String(32), nullable=False, server_default="active"),
        sa.Column("lifecycle_archive_reason", sa.String(32)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("ix_intent_instances_mochi_item_id", "intent_instances", ["mochi_item_id"])
    op.create_index(
        "ix_intent_instances_owner_type_lc",
        "intent_instances",
        ["owner_id", "intent_type", "lifecycle_kind"],
    )

    # 2) mochi_items.needs_review (LLM holistic boolean — 점수/threshold 폐기)
    op.add_column(
        "mochi_items",
        sa.Column("needs_review", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )

    # 3) 옛 intent 5컬럼 DROP (backfill 없음). intent 컬럼 인덱스는 컬럼과 함께 자동 삭제.
    op.drop_column("mochi_items", "intent")
    op.drop_column("mochi_items", "secondary_intents")
    op.drop_column("mochi_items", "intent_applicability")
    op.drop_column("mochi_items", "intent_candidates")
    op.drop_column("mochi_items", "confidence")

    # 4) lifecycle 의미 2분할 — 처리상태엔 archive_reason 없음(의미 lifecycle 은 intent_instances 로).
    op.drop_column("mochi_items", "lifecycle_archive_reason")


def downgrade() -> None:
    # 대칭 복원 — 5컬럼 ADD + needs_review/intent_instances 제거.
    op.add_column(
        "mochi_items",
        sa.Column("intent", sa.String(32), nullable=False, server_default="memo"),
    )
    op.create_index("ix_mochi_items_intent", "mochi_items", ["intent"])
    op.add_column(
        "mochi_items",
        sa.Column(
            "secondary_intents",
            postgresql.ARRAY(sa.String(32)),
            nullable=False,
            server_default=sa.text("'{}'::varchar[]"),
        ),
    )
    op.add_column(
        "mochi_items",
        sa.Column("intent_applicability", postgresql.JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
    )
    op.add_column(
        "mochi_items",
        sa.Column("intent_candidates", postgresql.JSONB, nullable=False, server_default=sa.text("'[]'::jsonb")),
    )
    op.add_column(
        "mochi_items",
        sa.Column("confidence", sa.Float(), nullable=False, server_default=sa.text("0")),
    )
    op.add_column("mochi_items", sa.Column("lifecycle_archive_reason", sa.String(32)))
    op.drop_column("mochi_items", "needs_review")
    op.drop_index("ix_intent_instances_owner_type_lc", table_name="intent_instances")
    op.drop_index("ix_intent_instances_mochi_item_id", table_name="intent_instances")
    op.drop_table("intent_instances")
