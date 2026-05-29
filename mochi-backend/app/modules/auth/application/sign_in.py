"""Sign-in use case — Apple/Google ID Token → 자체 access/refresh 발행.

흐름:
1. provider 별 verifier 로 ID Token 검증
2. (provider, subject) 로 기존 AuthAccount 조회 → 있으면 user 재사용
3. 없으면 신규 User + AuthAccount 동시 생성 (한 트랜잭션)
4. RefreshToken 신규 발급 (새 family), access JWT 발급
5. AuthTokens 반환

호출자가 ``db.commit()`` 를 책임진다 (presentation 레이어와 일관).
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.modules.auth.domain.entities import (
    AuthTokens,
    RefreshToken,
    User,
    VerifiedIdToken,
    new_family_id,
    new_refresh_token_id,
)
from app.modules.auth.domain.errors import AuthAccountRevokedError, UserDeletedError
from app.modules.auth.domain.ports import (
    AccessTokenIssuer,
    IdTokenVerifier,
    RefreshTokenIssuer,
    RefreshTokenRepository,
    UserRepository,
)
from app.shared.ids import UserID


@dataclass(frozen=True, slots=True)
class SignInResult:
    user: User
    tokens: AuthTokens
    was_signup: bool


@dataclass(frozen=True, slots=True)
class AppleSignInCommand:
    id_token: str
    nonce_raw: str | None
    # 첫 인가에만 Apple 이 제공. 이후 호출은 None.
    full_name: str | None = None
    device_label: str | None = None
    user_agent: str | None = None


@dataclass(frozen=True, slots=True)
class GoogleSignInCommand:
    id_token: str
    device_label: str | None = None
    user_agent: str | None = None


class SignIn:
    """Apple/Google ID Token 을 받아 자체 토큰을 발급하는 단일 use case.

    Apple/Google 의 차이는 ``IdTokenVerifier`` 가 흡수하고, 나머지(user upsert, token 발행) 는 공통이다.
    """

    def __init__(
        self,
        *,
        verifier: IdTokenVerifier,
        users: UserRepository,
        refresh_tokens: RefreshTokenRepository,
        access_issuer: AccessTokenIssuer,
        refresh_issuer: RefreshTokenIssuer,
    ) -> None:
        self._verifier = verifier
        self._users = users
        self._refresh_tokens = refresh_tokens
        self._access_issuer = access_issuer
        self._refresh_issuer = refresh_issuer

    async def with_apple(self, cmd: AppleSignInCommand) -> SignInResult:
        verified = await self._verifier.verify_apple(
            id_token=cmd.id_token,
            nonce_raw=cmd.nonce_raw,
        )
        return await self._finalize(
            verified=verified,
            display_name_hint=cmd.full_name,
            device_label=cmd.device_label,
            user_agent=cmd.user_agent,
        )

    async def with_google(self, cmd: GoogleSignInCommand) -> SignInResult:
        verified = await self._verifier.verify_google(id_token=cmd.id_token)
        return await self._finalize(
            verified=verified,
            display_name_hint=verified.name,
            device_label=cmd.device_label,
            user_agent=cmd.user_agent,
        )

    async def _finalize(
        self,
        *,
        verified: VerifiedIdToken,
        display_name_hint: str | None,
        device_label: str | None,
        user_agent: str | None,
    ) -> SignInResult:
        was_signup = False
        existing = await self._users.find_account(
            provider=verified.provider,
            subject=verified.subject,
        )
        if existing is None:
            # ``email_verified`` 가 false 인 IdP 토큰은 신뢰할 수 없는 주소 — 그 값을 그대로 저장하면
            # 공격자가 unverified email 로 진짜 사용자의 email 을 ``users.email UNIQUE`` 에서 선점할 수 있다.
            # placeholder 경로로 우회하고, 사용자가 추후 명시적으로 email 을 등록·확인하도록 한다.
            if verified.email and verified.email_verified:
                email = verified.email.lower()
            else:
                email = _placeholder_email(verified)
            user, _account = await self._users.create_user_and_account(
                provider=verified.provider,
                subject=verified.subject,
                email=email,
                display_name=(display_name_hint or "").strip(),
            )
            was_signup = True
        else:
            account, user = existing
            if account.revoked_at is not None:
                raise AuthAccountRevokedError(
                    "This auth account has been revoked",
                    code="auth.account_revoked",
                )
            if user.deleted_at is not None:
                raise UserDeletedError("User has been deleted", code="auth.user_deleted")
            # Apple 의 fullName 은 첫 인가에만 오므로, display_name 이 비어있고 hint 가 있으면 채운다.
            if not user.display_name and display_name_hint:
                await self._users.update_display_name_if_empty(
                    user_id=user.id,
                    display_name=display_name_hint.strip(),
                )
                user.display_name = display_name_hint.strip()

        tokens = await self._issue_tokens(
            user_id_=user.id,
            device_label=device_label,
            user_agent=user_agent,
        )
        return SignInResult(user=user, tokens=tokens, was_signup=was_signup)

    async def _issue_tokens(
        self,
        *,
        user_id_: UserID,
        device_label: str | None,
        user_agent: str | None,
    ) -> AuthTokens:
        now = datetime.now(UTC)
        access, access_exp = self._access_issuer.issue(user_id=user_id_, now=now)
        raw_refresh, refresh_hash, refresh_exp = self._refresh_issuer.generate(now=now)
        await self._refresh_tokens.add(
            RefreshToken(
                id=new_refresh_token_id(),
                user_id=user_id_,
                token_hash=refresh_hash,
                family_id=new_family_id(),
                parent_id=None,
                device_label=device_label,
                user_agent=user_agent,
                issued_at=now,
                expires_at=refresh_exp,
            )
        )
        return AuthTokens(
            access_token=access,
            access_token_expires_at=access_exp,
            refresh_token=raw_refresh,
            refresh_token_expires_at=refresh_exp,
        )


def _placeholder_email(verified: VerifiedIdToken) -> str:
    """email 이 없거나 unverified 일 때만 사용되는 stub. 사용자 노출 X."""

    safe_subject = verified.subject.replace("@", "_at_").replace(" ", "_")
    return f"{verified.provider.value}-{safe_subject}@unset.mochi.local"
