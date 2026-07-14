"""SQLAlchemy 기반 ``UserRepository`` + ``RefreshTokenRepository`` 구현."""

from datetime import datetime
from typing import Any, cast
from uuid import UUID

from sqlalchemy import CursorResult, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.auth.domain.entities import (
    AuthAccount,
    AuthProvider,
    CaptureToken,
    CaptureTokenRevokedReason,
    RefreshToken,
    RefreshTokenRevokedReason,
    User,
)
from app.modules.auth.domain.ports import (
    CaptureTokenRepository as CaptureTokenRepositoryPort,
)
from app.modules.auth.domain.ports import (
    RefreshTokenRepository as RefreshTokenRepositoryPort,
)
from app.modules.auth.domain.ports import UserRepository as UserRepositoryPort
from app.modules.auth.infrastructure.orm import (
    AuthAccountRow,
    CaptureTokenRow,
    RefreshTokenRow,
    UserRow,
)
from app.shared.ids import UserID


def _to_user(row: UserRow) -> User:
    return User(
        id=UserID(row.id),
        email=row.email,
        display_name=row.display_name,
        locale=row.locale,
        onboarding_completed_at=row.onboarding_completed_at,
        notify_recall_enabled=row.notify_recall_enabled,
        notify_analysis_enabled=row.notify_analysis_enabled,
        created_at=row.created_at,
        deleted_at=row.deleted_at,
    )


def _to_account(row: AuthAccountRow) -> AuthAccount:
    return AuthAccount(
        id=row.id,
        user_id=UserID(row.user_id),
        provider=AuthProvider(row.provider),
        subject=row.subject,
        email_at_link=row.email_at_link,
        linked_at=row.linked_at,
        revoked_at=row.revoked_at,
    )


def _to_capture(row: CaptureTokenRow) -> CaptureToken:
    return CaptureToken(
        id=row.id,
        user_id=UserID(row.user_id),
        token_hash=row.token_hash,
        device_label=row.device_label,
        issued_at=row.issued_at,
        expires_at=row.expires_at,
        last_used_at=row.last_used_at,
        revoked_at=row.revoked_at,
        revoked_reason=CaptureTokenRevokedReason(row.revoked_reason) if row.revoked_reason else None,
    )


def _to_refresh(row: RefreshTokenRow) -> RefreshToken:
    return RefreshToken(
        id=row.id,
        user_id=UserID(row.user_id),
        token_hash=row.token_hash,
        family_id=row.family_id,
        parent_id=row.parent_id,
        device_label=row.device_label,
        user_agent=row.user_agent,
        issued_at=row.issued_at,
        expires_at=row.expires_at,
        used_at=row.used_at,
        revoked_at=row.revoked_at,
        revoked_reason=RefreshTokenRevokedReason(row.revoked_reason) if row.revoked_reason else None,
    )


class PostgresUserRepository(UserRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_account(
        self,
        *,
        provider: AuthProvider,
        subject: str,
    ) -> tuple[AuthAccount, User] | None:
        stmt = (
            select(AuthAccountRow, UserRow)
            .join(UserRow, AuthAccountRow.user_id == UserRow.id)
            .where(AuthAccountRow.provider == provider.value)
            .where(AuthAccountRow.subject == subject)
            .limit(1)
        )
        result = await self._session.execute(stmt)
        row = result.first()
        if row is None:
            return None
        account_row, user_row = row
        return _to_account(account_row), _to_user(user_row)

    async def find_user(self, *, user_id: UserID) -> User | None:
        stmt = select(UserRow).where(UserRow.id == user_id).limit(1)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_user(row) if row else None

    async def create_user_and_account(
        self,
        *,
        provider: AuthProvider,
        subject: str,
        email: str,
        display_name: str,
        locale: str = "ko-KR",
    ) -> tuple[User, AuthAccount]:
        user_row = UserRow(
            email=email.lower(),
            display_name=display_name,
            locale=locale,
        )
        self._session.add(user_row)
        await self._session.flush()  # user_row.id 확보

        account_row = AuthAccountRow(
            user_id=user_row.id,
            provider=provider.value,
            subject=subject,
            email_at_link=email.lower(),
        )
        self._session.add(account_row)
        await self._session.flush()
        return _to_user(user_row), _to_account(account_row)

    async def update_display_name_if_empty(self, *, user_id: UserID, display_name: str) -> None:
        stmt = (
            update(UserRow)
            .where(UserRow.id == user_id)
            .where(UserRow.display_name == "")
            .values(display_name=display_name)
        )
        await self._session.execute(stmt)

    async def update_notification_preferences(
        self,
        *,
        user_id: UserID,
        recall_enabled: bool | None,
        analysis_enabled: bool | None,
    ) -> User | None:
        stmt = select(UserRow).where(UserRow.id == user_id).limit(1)
        row = (await self._session.execute(stmt)).scalar_one_or_none()
        if row is None:
            return None
        if recall_enabled is not None:
            row.notify_recall_enabled = recall_enabled
        if analysis_enabled is not None:
            row.notify_analysis_enabled = analysis_enabled
        await self._session.flush()
        return _to_user(row)

    async def mark_deleted(self, *, user_id: UserID, deleted_at: datetime) -> None:
        stmt = (
            update(UserRow)
            .where(UserRow.id == user_id)
            .where(UserRow.deleted_at.is_(None))
            .values(deleted_at=deleted_at)
        )
        await self._session.execute(stmt)

    async def upsert_user_with_id(
        self,
        *,
        user_id: UserID,
        email: str,
        display_name: str,
        locale: str = "ko-KR",
    ) -> User:
        existing = await self.find_user(user_id=user_id)
        if existing is not None:
            return existing
        row = UserRow(
            email=email.lower(),
            display_name=display_name,
            locale=locale,
        )
        # init=False 인 PK 를 caller-provided UUID 로 덮어쓴다 — RefreshTokenRow.add 와 동일 패턴.
        row.id = user_id
        self._session.add(row)
        await self._session.flush()
        return _to_user(row)


class PostgresRefreshTokenRepository(RefreshTokenRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def add(self, token: RefreshToken) -> None:
        row = RefreshTokenRow(
            user_id=token.user_id,
            token_hash=token.token_hash,
            family_id=token.family_id,
            parent_id=token.parent_id,
            device_label=token.device_label,
            user_agent=token.user_agent,
            issued_at=token.issued_at,
            expires_at=token.expires_at,
        )
        # caller-provided id 유지 (테스트 일관성)
        row.id = token.id
        self._session.add(row)
        await self._session.flush()

    async def find_by_hash(self, *, token_hash: str) -> RefreshToken | None:
        stmt = select(RefreshTokenRow).where(RefreshTokenRow.token_hash == token_hash).limit(1)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_refresh(row) if row else None

    async def mark_used(self, *, token_id: UUID, used_at: datetime) -> bool:
        # ``revoked_at`` 은 일부러 NULL 로 둔다 — 그래야 동일 raw 재사용을 ``is_revoked`` 가 아닌
        # ``is_used`` 분기에서 잡아 reuse_detected 흐름을 탈 수 있다.
        #
        # ``where(used_at IS NULL)`` 로 atomic compare-and-set. 두 요청이 동시에 실행되면 둘 다
        # 통과한 ``is_used`` 검사 뒤에도 DB 가 1 row 만 갱신하고 다른 호출은 0 row 를 받는다.
        # caller(``RotateRefreshToken``) 가 ``False`` 반환을 reuse_detected 로 처리한다.
        stmt = (
            update(RefreshTokenRow)
            .where(RefreshTokenRow.id == token_id)
            .where(RefreshTokenRow.used_at.is_(None))
            .values(used_at=used_at)
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return (result.rowcount or 0) > 0

    async def revoke(
        self,
        *,
        token_id: UUID,
        revoked_at: datetime,
        reason: RefreshTokenRevokedReason,
    ) -> None:
        stmt = (
            update(RefreshTokenRow)
            .where(RefreshTokenRow.id == token_id)
            .where(RefreshTokenRow.revoked_at.is_(None))
            .values(revoked_at=revoked_at, revoked_reason=reason.value)
        )
        await self._session.execute(stmt)

    async def revoke_family(
        self,
        *,
        family_id: UUID,
        revoked_at: datetime,
        reason: RefreshTokenRevokedReason,
    ) -> int:
        stmt = (
            update(RefreshTokenRow)
            .where(RefreshTokenRow.family_id == family_id)
            .where(RefreshTokenRow.revoked_at.is_(None))
            .values(revoked_at=revoked_at, revoked_reason=reason.value)
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return result.rowcount or 0


class PostgresCaptureTokenRepository(CaptureTokenRepositoryPort):
    # pg_advisory_xact_lock 의 classid 식별자 — 다른 advisory lock 사용처와 키 공간 분리.
    _ISSUE_LOCK_CLASS = 0x6D6374  # 'mct'

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def acquire_issue_lock(self, *, user_id: UserID) -> None:
        # (classid, hashtext(uuid)) 2-인자 형 — 트랜잭션 커밋/롤백 시 자동 해제.
        await self._session.execute(
            text("SELECT pg_advisory_xact_lock(:classid, hashtext(:uid))"),
            {"classid": self._ISSUE_LOCK_CLASS, "uid": str(user_id)},
        )

    async def add(self, token: CaptureToken) -> None:
        row = CaptureTokenRow(
            user_id=token.user_id,
            token_hash=token.token_hash,
            device_label=token.device_label,
            issued_at=token.issued_at,
            expires_at=token.expires_at,
        )
        # caller-provided id 유지 (테스트 일관성)
        row.id = token.id
        self._session.add(row)
        await self._session.flush()

    async def find_by_hash(self, *, token_hash: str) -> CaptureToken | None:
        stmt = select(CaptureTokenRow).where(CaptureTokenRow.token_hash == token_hash).limit(1)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_capture(row) if row else None

    async def list_active_for_user(self, *, user_id: UserID, now: datetime) -> list[CaptureToken]:
        stmt = (
            select(CaptureTokenRow)
            .where(CaptureTokenRow.user_id == user_id)
            .where(CaptureTokenRow.revoked_at.is_(None))
            .where(CaptureTokenRow.expires_at > now)
            .order_by(CaptureTokenRow.issued_at.asc())
        )
        result = await self._session.execute(stmt)
        return [_to_capture(row) for row in result.scalars().all()]

    async def touch(
        self,
        *,
        token_id: UUID,
        now: datetime,
        expires_at: datetime,
        debounce_cutoff: datetime,
    ) -> bool:
        # 디바운스 조건을 WHERE 에 내장한 조건부 UPDATE — sliding 연장이 시간당 최대 1회만
        # write 를 발생시킨다. 활성(미revoke) row 만 대상.
        stmt = (
            update(CaptureTokenRow)
            .where(CaptureTokenRow.id == token_id)
            .where(CaptureTokenRow.revoked_at.is_(None))
            .where(
                (CaptureTokenRow.last_used_at.is_(None)) | (CaptureTokenRow.last_used_at < debounce_cutoff)
            )
            .values(last_used_at=now, expires_at=expires_at)
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return (result.rowcount or 0) > 0

    async def revoke(
        self,
        *,
        token_id: UUID,
        revoked_at: datetime,
        reason: CaptureTokenRevokedReason,
    ) -> None:
        stmt = (
            update(CaptureTokenRow)
            .where(CaptureTokenRow.id == token_id)
            .where(CaptureTokenRow.revoked_at.is_(None))
            .values(revoked_at=revoked_at, revoked_reason=reason.value)
        )
        await self._session.execute(stmt)

    async def revoke_all_for_user(
        self,
        *,
        user_id: UserID,
        revoked_at: datetime,
        reason: CaptureTokenRevokedReason,
    ) -> int:
        stmt = (
            update(CaptureTokenRow)
            .where(CaptureTokenRow.user_id == user_id)
            .where(CaptureTokenRow.revoked_at.is_(None))
            .values(revoked_at=revoked_at, revoked_reason=reason.value)
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return result.rowcount or 0
