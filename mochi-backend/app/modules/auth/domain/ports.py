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
    CaptureToken,
    CaptureTokenRevokedReason,
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
    async def mark_deleted(self, *, user_id: UserID, deleted_at: datetime) -> None:
        """계정 soft delete — ``deleted_at`` 마킹(이미 삭제됐으면 no-op). sign-in/refresh 가
        ``deleted_at`` 을 거부하므로 이후 인증이 막힌다(mochi_item soft delete 와 동일 패턴)."""
        ...

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


class CaptureTokenRepository(ABC):
    """``capture_tokens`` 영속화. raw token 은 절대 받지 않으며, 모든 인자는 hash."""

    @abstractmethod
    async def acquire_issue_lock(self, *, user_id: UserID) -> None:
        """발급을 사용자 단위로 직렬화한다 (트랜잭션 종료 시 자동 해제).

        cap-eviction(list → revoke → add)이 비원자라, 동시 발급이 같은 active 목록을
        보면 cap 을 초과할 수 있다 — 발급 진입 시 이 lock 으로 직렬화해 닫는다.
        """

    @abstractmethod
    async def add(self, token: CaptureToken) -> None: ...

    @abstractmethod
    async def find_by_hash(self, *, token_hash: str) -> CaptureToken | None: ...

    @abstractmethod
    async def list_active_for_user(self, *, user_id: UserID, now: datetime) -> list[CaptureToken]:
        """revoke/만료되지 않은 토큰을 ``issued_at`` 오래된 순으로 반환 (발급 cap-eviction 용)."""

    @abstractmethod
    async def touch(
        self,
        *,
        token_id: UUID,
        now: datetime,
        expires_at: datetime,
        debounce_cutoff: datetime,
    ) -> bool:
        """sliding 연장 — ``last_used_at``/``expires_at`` 을 조건부 갱신.

        ``last_used_at IS NULL OR last_used_at < debounce_cutoff`` 인 활성 row 만 갱신해
        매 요청 UPDATE 부하를 디바운스한다. 갱신했으면 ``True``.
        """

    @abstractmethod
    async def revoke(
        self,
        *,
        token_id: UUID,
        revoked_at: datetime,
        reason: CaptureTokenRevokedReason,
    ) -> None: ...

    @abstractmethod
    async def revoke_all_for_user(
        self,
        *,
        user_id: UserID,
        revoked_at: datetime,
        reason: CaptureTokenRevokedReason,
    ) -> int:
        """해당 사용자의 ``revoked_at IS NULL`` 인 모든 토큰을 revoke. 영향받은 행 수 반환.

        refresh reuse 감지(도난 의심)·계정 탈퇴의 연쇄 revoke 훅이다.
        """


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


class CaptureTokenIssuer(ABC):
    """raw capture token secret 생성 + hash 계산 추상화 (``mct_`` prefix 포함)."""

    @abstractmethod
    def generate(self, *, now: datetime) -> tuple[str, str, datetime]:
        """``(raw_secret, sha256_hex, expires_at)`` 반환."""

    @abstractmethod
    def hash_existing(self, *, raw_secret: str) -> str:
        """클라이언트가 보낸 raw secret 의 hash 계산 (검증용)."""
