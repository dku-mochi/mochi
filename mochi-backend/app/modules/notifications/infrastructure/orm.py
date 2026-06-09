"""SQLAlchemy ORM row for device_push_tokens — 마이그레이션 0011 과 1:1.

owner 1:N 단말(apns_device) + owner 1:N Live Activity push-to-start(la_start) 토큰을 한 테이블에
token_type 으로 구분 저장한다. 둘 다 owner 단위라 mochi_item_id 는 NULL.
"""

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, ForeignKey, Index, String, Text
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
