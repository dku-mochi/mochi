from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, MappedAsDataclass

from app.core.config import get_settings


class Base(MappedAsDataclass, DeclarativeBase):
    """전체 ORM의 공통 베이스. SQLAlchemy 2.0 typed dataclass 스타일."""


_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def get_engine() -> AsyncEngine:
    global _engine
    if _engine is None:
        settings = get_settings()
        _engine = create_async_engine(
            settings.database_url,
            echo=False,
            pool_pre_ping=True,
            pool_size=settings.db_pool_size,
            max_overflow=settings.db_max_overflow,
            # 세션 타임존을 UTC 로 고정 — 코드 전반의 naive ``datetime.utcnow()`` 값이 timestamptz 컬럼에
            # 쓰일 때 세션 TZ 로 해석되므로, 서버 기본 TZ 가 무엇이든 UTC 로 일관 해석되게 한다
            # (회수 dismiss 쿨다운·stale-run 정리 등 시간 비교 정확성의 근본 봉인). asyncpg server_settings.
            connect_args={"server_settings": {"timezone": "UTC"}},
        )
    return _engine


def get_session_factory() -> async_sessionmaker[AsyncSession]:
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(get_engine(), expire_on_commit=False)
    return _session_factory


async def get_session() -> AsyncIterator[AsyncSession]:
    async with get_session_factory()() as session:
        yield session
