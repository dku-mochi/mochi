"""notification_plan + notification_outbox — 능동 회수 알림 발송 스키마.

"생성 분리(notification_plan) / 발송 통합(notification_outbox)". 정본
`journal/proactive-recall/schema.md` §1~§4. plan=계획(stages JSONB, 1 row), outbox=발송+반응 큐
(mochi_item_outbox 패턴의 시간축 확장 — BigInteger PK, FOR UPDATE SKIP LOCKED 클레임).

closed enum(plan_kind/status/cancel_reason/kind/skip_reason 일부)은 CheckConstraint 로 강제(0019
capture_tokens 패턴). occurrence identity 는 부분 UNIQUE(plan_id IS NOT NULL) — fire_at 은 가드로
바뀌니 identity 불가. owner_id 는 FK 안 붙임(denormalized, mochi_items/intent_instances 컨벤션).

Revision ID: 0023
Revises: 0022
Create Date: 2026-06-16 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0023"
down_revision: str | None = "0022"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # 1) notification_plan — 계획(stages JSONB 전체). cron 이 active 만 스캔(next_eligible_at).
    op.create_table(
        "notification_plan",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "source_intent_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("intent_instances.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "source_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("mochi_items.id", ondelete="SET NULL"),
        ),
        sa.Column("plan_kind", sa.String(16), nullable=False),
        sa.Column("dsl_version", sa.String(16), nullable=False),
        sa.Column("stages", postgresql.JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("status", sa.String(16), nullable=False, server_default="active"),
        sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        sa.Column("cancel_reason", sa.String(32)),
        sa.Column("generated_model", sa.String(64), nullable=False),
        sa.Column("next_eligible_at", sa.DateTime(timezone=True)),
        sa.Column(
            "superseded_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("notification_plan.id", ondelete="SET NULL"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "plan_kind IN ('deadline_backoff','recurring_nudge','spaced')",
            name="ck_np__plan_kind_enum",
        ),
        sa.CheckConstraint(
            "status IN ('active','superseded','done','cancelled')",
            name="ck_np__status_enum",
        ),
        sa.CheckConstraint(
            "cancel_reason IS NULL OR cancel_reason IN ('user_dismiss','intent_archived','superseded')",
            name="ck_np__cancel_reason_enum",
        ),
    )
    op.create_index("ix_notification_plan_owner_id", "notification_plan", ["owner_id"])
    op.create_index("ix_notification_plan_source_intent_id", "notification_plan", ["source_intent_id"])
    op.create_index("ix_notification_plan_status", "notification_plan", ["status"])
    op.create_index("ix_notification_plan_owner_status", "notification_plan", ["owner_id", "status"])
    op.create_index(
        "ix_notification_plan_status_next_eligible",
        "notification_plan",
        ["status", "next_eligible_at"],
    )
    # 같은 source_intent 에 active plan 1개만(plan 폭증 방지, codex-3). 앱 read-then-write 만으론
    # worker_concurrency 동시성에서 race → DB 부분 UNIQUE 로 보장. 충돌 시 유스케이스가 skip.
    op.create_index(
        "ux_notification_plan_active_intent",
        "notification_plan",
        ["owner_id", "source_intent_id"],
        unique=True,
        postgresql_where=sa.text("status = 'active'"),
    )

    # 2) notification_outbox — 발송 + 반응(mochi_item_outbox 패턴). 트랙 C 회수는 plan_id NULL 직행.
    op.create_table(
        "notification_outbox",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "plan_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("notification_plan.id", ondelete="SET NULL"),
        ),
        sa.Column("stage_seq", sa.Integer),
        sa.Column("occurrence_seq", sa.Integer),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "source_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("mochi_items.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "source_intent_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("intent_instances.id", ondelete="SET NULL"),
        ),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("fire_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True)),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("body", sa.String(), nullable=False),
        sa.Column("collapse_id", sa.String()),
        sa.Column("status", sa.String(16), nullable=False, server_default="pending"),
        sa.Column("skip_reason", sa.String()),
        sa.Column("next_retry_at", sa.DateTime(timezone=True)),
        sa.Column("attempts", sa.Integer, nullable=False, server_default=sa.text("0")),
        sa.Column("locked_until", sa.DateTime(timezone=True)),
        sa.Column("last_error", sa.String()),
        sa.Column("sent_at", sa.DateTime(timezone=True)),
        sa.Column("opened_at", sa.DateTime(timezone=True)),
        sa.Column("dismissed_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "kind IN ('deadline','nudge','spaced','recall')",
            name="ck_no__kind_enum",
        ),
        sa.CheckConstraint(
            "status IN ('pending','sent','deferred','skipped','dead_letter')",
            name="ck_no__status_enum",
        ),
        # plan 기반 row 는 두 seq 가 항상 채워져야 한다 — 안 그러면 부분 UNIQUE 가 NULL 을 distinct
        # 취급해 중복 발송 방지 불변식이 DB 레벨에서 붕괴한다(schema.md §5). 트랙 C 직행(plan_id NULL)은 허용.
        sa.CheckConstraint(
            "plan_id IS NULL OR (stage_seq IS NOT NULL AND occurrence_seq IS NOT NULL)",
            name="ck_no__plan_row_has_seq",
        ),
    )
    op.create_index("ix_notification_outbox_owner_id", "notification_outbox", ["owner_id"])
    op.create_index("ix_notification_outbox_kind", "notification_outbox", ["kind"])
    op.create_index("ix_notification_outbox_fire_at", "notification_outbox", ["fire_at"])
    op.create_index("ix_notification_outbox_status", "notification_outbox", ["status"])
    op.create_index(
        "ix_notification_outbox_status_fire_at",
        "notification_outbox",
        ["status", "fire_at"],
    )
    # 가드로 fire_at 흔들려도 occurrence identity 로 중복 발송 방지. 트랙 C 직행(plan_id NULL)은 제외.
    op.create_index(
        "ux_notification_outbox_occurrence",
        "notification_outbox",
        ["plan_id", "stage_seq", "occurrence_seq"],
        unique=True,
        postgresql_where=sa.text("plan_id IS NOT NULL"),
    )


def downgrade() -> None:
    # outbox 먼저 drop (plan_id FK 의존). 인덱스는 테이블과 함께 삭제되나 명시 drop 으로 대칭 유지.
    op.drop_index("ux_notification_outbox_occurrence", table_name="notification_outbox")
    op.drop_index("ix_notification_outbox_status_fire_at", table_name="notification_outbox")
    op.drop_index("ix_notification_outbox_status", table_name="notification_outbox")
    op.drop_index("ix_notification_outbox_fire_at", table_name="notification_outbox")
    op.drop_index("ix_notification_outbox_kind", table_name="notification_outbox")
    op.drop_index("ix_notification_outbox_owner_id", table_name="notification_outbox")
    op.drop_table("notification_outbox")

    op.drop_index("ux_notification_plan_active_intent", table_name="notification_plan")
    op.drop_index("ix_notification_plan_status_next_eligible", table_name="notification_plan")
    op.drop_index("ix_notification_plan_owner_status", table_name="notification_plan")
    op.drop_index("ix_notification_plan_status", table_name="notification_plan")
    op.drop_index("ix_notification_plan_source_intent_id", table_name="notification_plan")
    op.drop_index("ix_notification_plan_owner_id", table_name="notification_plan")
    op.drop_table("notification_plan")
