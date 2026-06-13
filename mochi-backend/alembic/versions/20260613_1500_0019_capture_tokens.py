"""capture_tokens — ShareExtension 직접 전송용 capture-scoped opaque token.

access JWT(30분) 만료 때문에 ShareExt 직접 전송이 자주 실패하던 문제의 해결.
ingest + presign 라우트에서만 유효한 장수명 토큰을 별도 테이블로 격리한다.

- ``refresh_tokens`` 의 hash-only 보관 패턴 미러 (raw 는 클라이언트 Keychain 에만).
- 회전(family/parent/used_at) 없음 — sliding 만료(검증 시 연장) + revoke 가 수명 통제.
- revoke 연쇄: logout / cap-eviction / refresh reuse 감지 / 계정 탈퇴(미래 훅).

Revision ID: 0019
Revises: 0018
Create Date: 2026-06-13 15:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0019"
down_revision: str | None = "0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "capture_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        # SHA-256(raw token, 'mct_' prefix 포함) 64-hex. raw 는 클라이언트에만, DB 엔 항상 hash.
        sa.Column("token_hash", sa.String(64), nullable=False),
        # 디바이스 진단 정보 (옵션)
        sa.Column("device_label", sa.String(128)),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        # sliding — 검증 시 ``now + TTL`` 로 연장된다 (1h 디바운스).
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        # 관측·디바운스 기준. 의미 부하 없음 (만료 판단은 expires_at 단독).
        sa.Column("last_used_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_reason", sa.String(32)),
        sa.UniqueConstraint("token_hash", name="uq_ct__token_hash"),
        sa.CheckConstraint("expires_at > issued_at", name="ck_ct__expires"),
        sa.CheckConstraint(
            "(revoked_at IS NULL) = (revoked_reason IS NULL)",
            name="ck_ct__revoke_paired",
        ),
        sa.CheckConstraint(
            "revoked_reason IS NULL OR revoked_reason IN "
            "('logout','evicted','reuse_detected','user_account_deleted','admin')",
            name="ck_ct__revoke_reason_enum",
        ),
    )
    op.create_index("idx_ct__user", "capture_tokens", ["user_id"])
    op.create_index(
        "idx_ct__user_active",
        "capture_tokens",
        ["user_id", "issued_at"],
        postgresql_where=sa.text("revoked_at IS NULL"),
    )
    op.create_index(
        "idx_ct__expires_active",
        "capture_tokens",
        ["expires_at"],
        postgresql_where=sa.text("revoked_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("idx_ct__expires_active", table_name="capture_tokens")
    op.drop_index("idx_ct__user_active", table_name="capture_tokens")
    op.drop_index("idx_ct__user", table_name="capture_tokens")
    op.drop_table("capture_tokens")
