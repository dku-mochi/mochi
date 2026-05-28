"""Auth 도메인 엔티티 — 프레임워크 의존 없음.

- ``User``: 모찌 계정 aggregate root. 식별자 + 표시 정보 + soft delete.
- ``AuthAccount``: 외부 IdP(Apple/Google) 와 User 의 연결. (provider, subject) 유일.
- ``RefreshToken``: 자체 발행 회전 가능 refresh token. token_hash 만 보관, raw 는 절대 저장 안함.
- ``AuthTokens``: presentation/응답 전용 페어 (access JWT + raw refresh secret).
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from app.shared.ids import UserID


class AuthProvider(StrEnum):
    """외부 ID provider. DB CHECK 와 일치."""

    APPLE = "apple"
    GOOGLE = "google"


@dataclass(slots=True)
class User:
    """모찌 사용자. ``id`` 가 모든 owner-scoped 데이터의 기준."""

    id: UserID
    email: str
    display_name: str = ""
    locale: str = "ko-KR"
    onboarding_completed_at: datetime | None = None
    created_at: datetime = field(default_factory=lambda: datetime.utcnow())
    deleted_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class AuthAccount:
    """외부 IdP 와 ``User`` 의 결합."""

    id: UUID
    user_id: UserID
    provider: AuthProvider
    subject: str
    email_at_link: str
    linked_at: datetime
    revoked_at: datetime | None = None


class RefreshTokenRevokedReason(StrEnum):
    """``refresh_tokens.revoked_reason`` enum. DB CHECK 와 일치."""

    ROTATED = "rotated"
    LOGOUT = "logout"
    REUSE_DETECTED = "reuse_detected"
    USER_ACCOUNT_DELETED = "user_account_deleted"
    ADMIN = "admin"


@dataclass(slots=True)
class RefreshToken:
    """회전 가능한 refresh token 의 도메인 표현.

    raw secret 은 클라이언트에만 존재한다. 도메인/저장소 어디서도 raw 를 절대 보관하지 않으며,
    검증은 항상 ``token_hash`` (SHA-256 hex) 매칭으로만 수행한다.
    """

    id: UUID
    user_id: UserID
    token_hash: str
    family_id: UUID
    parent_id: UUID | None
    device_label: str | None
    user_agent: str | None
    issued_at: datetime
    expires_at: datetime
    used_at: datetime | None = None
    revoked_at: datetime | None = None
    revoked_reason: RefreshTokenRevokedReason | None = None

    @property
    def is_revoked(self) -> bool:
        return self.revoked_at is not None

    @property
    def is_used(self) -> bool:
        return self.used_at is not None

    def is_expired(self, now: datetime) -> bool:
        return now >= self.expires_at


@dataclass(frozen=True, slots=True)
class AuthTokens:
    """클라이언트에 한 번만 전달되는 token pair.

    refresh secret 은 평문 그대로 1회 전달 — 클라이언트가 Keychain 에 보관해야 한다.
    이후 어떤 응답에도 같은 raw 가 다시 노출되지 않는다.
    """

    access_token: str
    access_token_expires_at: datetime
    refresh_token: str
    refresh_token_expires_at: datetime


@dataclass(frozen=True, slots=True)
class VerifiedIdToken:
    """외부 IdP ID Token 검증 결과 (provider-agnostic).

    - ``subject`` 는 provider 가 발급한 사용자 고유 식별자.
    - ``email`` 은 옵션 (Apple 은 첫 인가에만, Google 은 보통 항상 제공).
    - ``email_verified`` 가 False 이면 신뢰할 수 없는 이메일.
    """

    provider: AuthProvider
    subject: str
    email: str | None
    email_verified: bool
    name: str | None = None


def new_refresh_token_id() -> UUID:
    return uuid4()


def new_family_id() -> UUID:
    return uuid4()
