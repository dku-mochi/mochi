"""auth: users + auth_accounts + refresh_tokens.

Apple/Google Sign-In + 자체 발행 access/refresh token rotation 을 위한 3개 테이블.

- ``users``: DOMAIN_DESIGN §4.2 그대로. email 은 lower-case CHECK + active partial unique.
- ``auth_accounts``: provider ∈ {'apple','google'}, (provider, subject) UNIQUE.
- ``refresh_tokens``: 신규. token_hash UNIQUE + family_id 로 rotation chain 유지,
  used_at 마크된 토큰 재사용 시 family 전체 revoke (reuse_detected) 가능하도록 컬럼 보강.

캡처/owner_id FK 추가는 본 마이그레이션 범위 밖. dev 토큰 sha256 → UUID 호환 보존 위해
``captures.owner_id`` 는 application-level 보장만 유지한다.

Revision ID: 0004
Revises: 0003
Create Date: 2026-05-23 02:30:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("display_name", sa.String(128), nullable=False, server_default=""),
        sa.Column("locale", sa.String(16), nullable=False, server_default="ko-KR"),
        sa.Column("onboarding_completed_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("email = lower(email)", name="ck_users__email_lower"),
    )
    op.create_index(
        "uq_users__email__active",
        "users",
        ["email"],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "auth_accounts",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("provider", sa.String(16), nullable=False),
        sa.Column("subject", sa.String(255), nullable=False),
        sa.Column("email_at_link", sa.String(320), nullable=False),
        sa.Column("linked_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("provider IN ('apple','google')", name="ck_auth__provider"),
        sa.UniqueConstraint("provider", "subject", name="uq_auth__provider_subject"),
    )
    op.create_index("idx_auth__user", "auth_accounts", ["user_id"])

    op.create_table(
        "refresh_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        # SHA-256(raw token) 64-hex. raw token 은 클라이언트에만, DB 엔 항상 hash.
        sa.Column("token_hash", sa.String(64), nullable=False),
        # 같은 디바이스/세션에서 회전되는 토큰 체인의 family. reuse 감지 시 family 전체 revoke.
        sa.Column("family_id", postgresql.UUID(as_uuid=True), nullable=False),
        # 회전된 직전 토큰. 도난 분석에 유용.
        sa.Column(
            "parent_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("refresh_tokens.id", ondelete="SET NULL"),
        ),
        # 디바이스 / UA 등 진단 정보 (옵션)
        sa.Column("device_label", sa.String(128)),
        sa.Column("user_agent", sa.String(512)),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        # 정상 회전 시 used_at 마크. 같은 family 의 used 토큰이 다시 들어오면 reuse_detected.
        sa.Column("used_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_reason", sa.String(32)),
        sa.UniqueConstraint("token_hash", name="uq_rt__token_hash"),
        sa.CheckConstraint("expires_at > issued_at", name="ck_rt__expires"),
        sa.CheckConstraint(
            "(revoked_at IS NULL) = (revoked_reason IS NULL)",
            name="ck_rt__revoke_paired",
        ),
        sa.CheckConstraint(
            "revoked_reason IS NULL OR revoked_reason IN "
            "('rotated','logout','reuse_detected','user_account_deleted','admin')",
            name="ck_rt__revoke_reason_enum",
        ),
    )
    op.create_index("idx_rt__user", "refresh_tokens", ["user_id"])
    op.create_index(
        "idx_rt__family_active",
        "refresh_tokens",
        ["family_id"],
        postgresql_where=sa.text("revoked_at IS NULL"),
    )
    op.create_index(
        "idx_rt__expires_active",
        "refresh_tokens",
        ["expires_at"],
        postgresql_where=sa.text("revoked_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("idx_rt__expires_active", table_name="refresh_tokens")
    op.drop_index("idx_rt__family_active", table_name="refresh_tokens")
    op.drop_index("idx_rt__user", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")

    op.drop_index("idx_auth__user", table_name="auth_accounts")
    op.drop_table("auth_accounts")

    op.drop_index("uq_users__email__active", table_name="users")
    op.drop_table("users")
