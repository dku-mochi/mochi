"""SQLAlchemy ORM rows — device_push_tokens(0011) + notification_plan/outbox(0023).

device_push_tokens: owner 1:N 단말(apns_device) + owner 1:N Live Activity push-to-start(la_start)
토큰을 한 테이블에 token_type 으로 구분 저장한다. 둘 다 owner 단위라 mochi_item_id 는 NULL.

notification_plan / notification_outbox: 능동 회수 알림 — "생성 분리 / 발송 통합".
정본 `journal/proactive-recall/schema.md` §1~§4. plan=계획(stages JSONB), outbox=발송+반응 큐.
"""

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import (
    UUID as PgUUIDColumn,  # noqa: N811
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class DevicePushTokenRow(Base):
    __tablename__ = "device_push_tokens"

    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    owner_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    token: Mapped[str] = mapped_column(Text)
    token_type: Mapped[str] = mapped_column(String(16))
    # apns_device·la_start 토큰은 owner 단위라 NULL. 컬럼은 구 per-item LA 토큰 호환을 위해 보존
    # (SET NULL — item 삭제 시 행만 남음). 현 등록 경로는 모두 mochi_item_id 를 채우지 않는다.
    mochi_item_id: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True), ForeignKey("mochi_items.id", ondelete="SET NULL"), default=None
    )
    environment: Mapped[str] = mapped_column(String(16), default="sandbox")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)

    __table_args__ = (
        # token 자체가 globally unique. apns_device 토큰은 폰 단위라 계정 전환 시 owner 를 갱신해야
        # 한다(이전 owner row 가 남으면 그 owner 분석완료가 새 owner 폰으로 push 되는 cross-account 유출).
        # LA 토큰은 item별 고유. device/LA 토큰은 형식이 달라 충돌하지 않는다.
        Index("ux_device_push_tokens_token", "token", unique=True),
    )


class NotificationPlanRow(Base):
    """능동 회수 알림 "계획" — 알림 설계 Agent 가 1 row 로 적재. schema.md §1.

    `stages`(JSONB) 가 계획 전체(다단/주기/spaced)를 담는다. anchor 값은 캐시하지 않고 심볼로 참조 →
    cron 이 발송 때 `intent_instances.payload` 를 최신 조회(마감 수정 자동 추종). owner_id 는 FK 를
    붙이지 않는다 — mochi_items/intent_instances 와 동일한 denormalized 컨벤션.
    """

    __tablename__ = "notification_plan"

    # MappedAsDataclass: 기본값 없는(필수) 컬럼을 먼저, 기본값 있는 컬럼을 뒤에 둔다(IntentInstanceRow 패턴).
    id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True), primary_key=True, insert_default=uuid4, init=False
    )
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), index=True)
    source_intent_id: Mapped[UUID] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("intent_instances.id", ondelete="CASCADE"),
        index=True,
    )
    plan_kind: Mapped[str] = mapped_column(String(16))  # deadline_backoff | recurring_nudge | spaced
    dsl_version: Mapped[str] = mapped_column(String(16))
    generated_model: Mapped[str] = mapped_column(String(64))
    source_item_id: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("mochi_items.id", ondelete="SET NULL"),
        default=None,
    )
    stages: Mapped[dict[str, Any]] = mapped_column(JSONB, default_factory=dict)
    status: Mapped[str] = mapped_column(
        String(16), default="active", index=True
    )  # active | superseded | done | cancelled
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    cancel_reason: Mapped[str | None] = mapped_column(
        String(32), default=None
    )  # user_dismiss | intent_archived | superseded
    next_eligible_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    superseded_by: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("notification_plan.id", ondelete="SET NULL"),
        default=None,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default_factory=datetime.utcnow, onupdate=datetime.utcnow
    )

    __table_args__ = (
        # closed enum 강제 — migration 0023 과 name+SQL 동일(autogenerate drift 방지).
        CheckConstraint(
            "plan_kind IN ('deadline_backoff','recurring_nudge','spaced')",
            name="ck_np__plan_kind_enum",
        ),
        CheckConstraint(
            "status IN ('active','superseded','done','cancelled')",
            name="ck_np__status_enum",
        ),
        CheckConstraint(
            "cancel_reason IS NULL OR cancel_reason IN ('user_dismiss','intent_archived','superseded')",
            name="ck_np__cancel_reason_enum",
        ),
        Index("ix_notification_plan_owner_status", "owner_id", "status"),
        # 대량 import/재분석 시 plan 폭증 대비 cron 스캔 — next_eligible_at <= now 인 active 만.
        Index("ix_notification_plan_status_next_eligible", "status", "next_eligible_at"),
        # 같은 source_intent 에 active plan 1개만(plan 폭증 방지, codex-3). 동시 워커 race 를 DB 가 막는다.
        Index(
            "ux_notification_plan_active_intent",
            "owner_id",
            "source_intent_id",
            unique=True,
            postgresql_where=text("status = 'active'"),
        ),
    )


class NotificationOutboxRow(Base):
    """능동 회수 알림 "발송 + 반응" 큐 — mochi_item_outbox 패턴(BigInteger PK)의 시간축 확장. schema.md §2.

    cron 이 active plan 의 다음 occurrence 를 lazy materialize → 가드 통과분만 1 row.
    트랙 C 회수는 plan 없이 직행(plan_id NULL, kind=recall). sent/opened/dismissed 가 recall_log 흡수.
    """

    __tablename__ = "notification_outbox"

    # MappedAsDataclass: 기본값 없는(필수) 컬럼을 먼저, 기본값 있는 컬럼을 뒤에 둔다(MochiItemOutboxRow 패턴).
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    event_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), insert_default=uuid4, init=False)
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), index=True)
    kind: Mapped[str] = mapped_column(String(16), index=True)  # deadline | nudge | spaced | recall
    fire_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    title: Mapped[str] = mapped_column(String)
    body: Mapped[str] = mapped_column(String)
    plan_id: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("notification_plan.id", ondelete="SET NULL"),
        default=None,
    )
    stage_seq: Mapped[int | None] = mapped_column(Integer, default=None)
    occurrence_seq: Mapped[int | None] = mapped_column(Integer, default=None)
    source_item_id: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("mochi_items.id", ondelete="SET NULL"),
        default=None,
    )
    source_intent_id: Mapped[UUID | None] = mapped_column(
        PgUUIDColumn(as_uuid=True),
        ForeignKey("intent_instances.id", ondelete="SET NULL"),
        default=None,
    )
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    collapse_id: Mapped[str | None] = mapped_column(String, default=None)
    status: Mapped[str] = mapped_column(
        String(16), default="pending", index=True
    )  # pending | sent | deferred | skipped | dead_letter
    skip_reason: Mapped[str | None] = mapped_column(String, default=None)
    next_retry_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    last_error: Mapped[str | None] = mapped_column(String, default=None)
    sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    opened_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    dismissed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    # 사용자가 발송 시각을 옮기면(reschedule) 모찌 원안 fire_at 을 1회 보존(COALESCE). NULL=미조정(현 fire_at=원안).
    # worker 는 이 컬럼을 읽지 않는다(fire_at 만 스캔) — pending fire_at 직접 갱신의 무변경 불변식 유지.
    original_fire_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default_factory=datetime.utcnow, onupdate=datetime.utcnow
    )

    __table_args__ = (
        # closed enum 강제 — migration 0023 과 name+SQL 동일(autogenerate drift 방지).
        CheckConstraint(
            "kind IN ('deadline','nudge','spaced','recall')",
            name="ck_no__kind_enum",
        ),
        CheckConstraint(
            "status IN ('pending','sent','deferred','skipped','dead_letter')",
            name="ck_no__status_enum",
        ),
        # plan 기반 row 는 두 seq 가 항상 채워져야 한다 — NULL 이면 부분 UNIQUE 가 distinct 취급해
        # 중복 발송 방지 불변식이 DB 레벨에서 붕괴(schema.md §5). 트랙 C 직행(plan_id NULL)은 허용.
        CheckConstraint(
            "plan_id IS NULL OR (stage_seq IS NOT NULL AND occurrence_seq IS NOT NULL)",
            name="ck_no__plan_row_has_seq",
        ),
        Index("ix_notification_outbox_status_fire_at", "status", "fire_at"),
        # 가드로 fire_at 이 흔들려도 occurrence identity 로 중복 발송 방지. 트랙 C 직행(plan_id NULL) 은 제외.
        Index(
            "ux_notification_outbox_occurrence",
            "plan_id",
            "stage_seq",
            "occurrence_seq",
            unique=True,
            postgresql_where=text("plan_id IS NOT NULL"),
        ),
    )
