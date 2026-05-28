"""Auth 모듈 outbound port (Hexagonal).

application layer 는 이 추상 인터페이스만 의존하고, infrastructure 가 구체 구현을 제공한다.
domain layer 는 jwt/sqlalchemy/httpx 어떤 외부 패키지도 import 하지 않는다.
"""

from abc import ABC, abstractmethod
from datetime import datetime
from uuid import UUID

from app.modules.auth.domain.entities import (
    AuthAccount,
    AuthProvider,
    RefreshToken,
    RefreshTokenRevokedReason,
    User,
    VerifiedIdToken,
)
from app.shared.ids import UserID


class IdTokenVerifier(ABC):
    """외부 IdP(Apple/Google) ID Token 검증 추상화."""

    @abstractmethod
    async def verify_apple(self, *, id_token: str, nonce_raw: str | None) -> VerifiedIdToken: ...

    @abstractmethod
    async def verify_google(self, *, id_token: str) -> VerifiedIdToken: ...


class UserRepository(ABC):
    """``users`` + ``auth_accounts`` 영속화. owner-scoped 데이터의 진실 공급원."""

    @abstractmethod
    async def find_account(
        self,
        *,
        provider: AuthProvider,
        subject: str,
    ) -> tuple[AuthAccount, User] | None: ...

    @abstractmethod
    async def find_user(self, *, user_id: UserID) -> User | None: ...

    @abstractmethod
    async def create_user_and_account(
        self,
        *,
        provider: AuthProvider,
        subject: str,
        email: str,
        display_name: str,
        locale: str = "ko-KR",
    ) -> tuple[User, AuthAccount]: ...

    @abstractmethod
    async def update_display_name_if_empty(self, *, user_id: UserID, display_name: str) -> None: ...

    @abstractmethod
    async def upsert_user_with_id(
        self,
        *,
        user_id: UserID,
        email: str,
        display_name: str,
        locale: str = "ko-KR",
    ) -> User:
        """주어진 ``user_id`` 의 user 가 있으면 그대로 반환, 없으면 생성한다.

        dev sign-in 전용 — subject 로부터 결정론적으로 derive 된 UUID 를 그대로 PK 로
        사용해 (provider, subject) 인덱스 없이도 멱등성을 확보한다. auth_accounts 는
        건드리지 않는다 (CHECK provider IN ('apple','google') 제약 회피).
        """


class RefreshTokenRepository(ABC):
    """``refresh_tokens`` 영속화. raw token 은 절대 받지 않으며, 모든 인자는 hash."""

    @abstractmethod
    async def add(self, token: RefreshToken) -> None: ...

    @abstractmethod
    async def find_by_hash(self, *, token_hash: str) -> RefreshToken | None: ...

    @abstractmethod
    async def mark_used(self, *, token_id: UUID, used_at: datetime) -> bool:
        """``used_at IS NULL`` 인 row 만 atomically 갱신. 우리가 이긴 경우에만 ``True``.

        동시 회전 race 에서 진 호출은 ``False`` 를 받아 reuse_detected 로 분기해야 한다.
        """

    @abstractmethod
    async def revoke(
        self,
        *,
        token_id: UUID,
        revoked_at: datetime,
        reason: RefreshTokenRevokedReason,
    ) -> None: ...

    @abstractmethod
    async def revoke_family(
        self,
        *,
        family_id: UUID,
        revoked_at: datetime,
        reason: RefreshTokenRevokedReason,
    ) -> int:
        """family 안의 ``revoked_at IS NULL`` 인 모든 토큰을 revoke. 영향받은 행 수 반환."""


class AccessTokenIssuer(ABC):
    """자체 발행 access JWT 발급/검증 추상화.

    iss/aud/secret 등 정책 파라미터는 구현에서 ``Settings`` 로부터 주입한다.
    """

    @abstractmethod
    def issue(self, *, user_id: UserID, now: datetime) -> tuple[str, datetime]:
        """``(access_token_jwt, expires_at)`` 반환."""

    @abstractmethod
    def verify(self, *, token: str) -> UserID:
        """검증 실패 시 ``UnauthorizedError`` 계열 raise."""


class RefreshTokenIssuer(ABC):
    """raw refresh token secret 생성 + hash 계산 추상화.

    secret 의 형식·길이·hash 알고리즘은 단일 구현에서 책임진다.
    """

    @abstractmethod
    def generate(self, *, now: datetime) -> tuple[str, str, datetime]:
        """``(raw_secret, sha256_hex, expires_at)`` 반환."""

    @abstractmethod
    def hash_existing(self, *, raw_secret: str) -> str:
        """클라이언트가 보낸 raw secret 의 hash 계산 (검증용)."""
