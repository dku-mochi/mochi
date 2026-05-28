"""Transactional outbox 패턴.

MochiItem 이 persisted 되는 트랜잭션 내에서 같은 트랜잭션에 `capture_outbox` 행을 한 줄 추가한다.
별도 worker가 outbox를 polling 하며 ``AgentOrchestrator`` 를 호출하고,
처리 완료 시 행을 archived 시킨다.

이 패턴이 표준인 이유:
- "DB 커밋은 성공했는데 큐 발행은 실패" 같은 dual-write 문제를 컴파일적으로 차단
- Postgres `LISTEN/NOTIFY` 한 채널로 worker에 즉시 wake-up 신호 전달 가능
- 일반 SQL 도구로 진단·재시도·dead-letter 처리가 가능
"""

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, DateTime, ForeignKey, Integer, String
from sqlalchemy.dialects.postgresql import UUID as PgUUIDColumn  # noqa: N811
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class MochiItemOutboxRow(Base):
    __tablename__ = "capture_outbox"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True, init=False)
    event_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), insert_default=uuid4, init=False)
    capture_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), ForeignKey("captures.id", ondelete="CASCADE"), index=True)
    owner_id: Mapped[UUID] = mapped_column(PgUUIDColumn(as_uuid=True), index=True)
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(String, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default_factory=datetime.utcnow)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)


class OutboxNotifier:
    """MochiItem 생성 트랜잭션 안에서 호출되어, 같은 트랜잭션에 outbox 행을 적재한다.

    호출자(`PostgresMochiItemRepository` + `Ingest`)가 `session.commit()` 하면
    트랜잭션이 함께 커밋되어 atomic 보장. 이후 Postgres `pg_notify('capture_outbox', ...)` 로
    백그라운드 worker 에 즉시 wake-up 신호를 보낸다.
    """

    def __init__(self, session: AsyncSession):
        self._session = session

    async def emit(self, *, owner_id: UUID, mochi_item_id: UUID) -> None:
        row = MochiItemOutboxRow(
            capture_id=mochi_item_id,
            owner_id=owner_id,
        )
        self._session.add(row)
        await self._session.flush()
        # LISTEN/NOTIFY 즉시 wake-up — payload 는 mochi_item_id 만으로 충분.
        from sqlalchemy import text

        await self._session.execute(text("SELECT pg_notify('capture_outbox', :mochi_item_id)"),
                                    {"mochi_item_id": str(mochi_item_id)})
