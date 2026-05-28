"""Dev sign-in use case — Apple/Google 없이 subject 만으로 access/refresh 발행.

local 환경 전용. ``app.core.security._derive_dev_user_id`` 와 동일한 SHA-256 결정론적
UUID 를 사용해 기존 dev 토큰(``Bearer dev:<subject>``) 흐름과 같은 ``UserID`` 를 만든다.
같은 subject 로 여러 번 호출해도 항상 같은 user 가 반환된다 (멱등).

``auth_accounts`` 는 건드리지 않는다 — provider CHECK 제약을 회피하고, 이 사용자가
정식 Apple/Google 로그인을 추후 시도해도 (provider, subject) lookup 이 정상 작동한다.

호출자가 ``db.commit()`` 를 책임진다 (presentation 레이어와 일관).
"""

import hashlib
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

from app.modules.auth.application.sign_in import SignInResult
from app.modules.auth.domain.entities import (
    AuthTokens,
    RefreshToken,
    new_family_id,
    new_refresh_token_id,
)
from app.modules.auth.domain.ports import (
    AccessTokenIssuer,
    RefreshTokenIssuer,
    RefreshTokenRepository,
    UserRepository,
)
from app.shared.ids import UserID


@dataclass(frozen=True, slots=True)
class DevSignInCommand:
    subject: str
    display_name: str | None = None
    device_label: str | None = None
    user_agent: str | None = None


def derive_dev_user_id(subject: str) -> UserID:
    """``app.core.security._derive_dev_user_id`` 와 동일한 derivation. dev 토큰 호환."""

    digest = hashlib.sha256(subject.encode("utf-8")).digest()[:16]
    return UserID(UUID(bytes=digest, version=4))


class DevSignIn:
    """Local-only sign-in. 호출자(라우터)가 environment=local 가드를 책임진다."""

    def __init__(
        self,
        *,
        users: UserRepository,
        refresh_tokens: RefreshTokenRepository,
        access_issuer: AccessTokenIssuer,
        refresh_issuer: RefreshTokenIssuer,
    ) -> None:
        self._users = users
        self._refresh_tokens = refresh_tokens
        self._access_issuer = access_issuer
        self._refresh_issuer = refresh_issuer

    async def execute(self, cmd: DevSignInCommand) -> SignInResult:
        subject = cmd.subject.strip()
        user_id = derive_dev_user_id(subject)
        display_name = (cmd.display_name or subject).strip()
        email = f"dev-{subject}@dev.mochi.local".lower()

        existed_before = await self._users.find_user(user_id=user_id) is not None
        user = await self._users.upsert_user_with_id(
            user_id=user_id,
            email=email,
            display_name=display_name,
        )

        tokens = await self._issue_tokens(
            user_id_=user.id,
            device_label=cmd.device_label,
            user_agent=cmd.user_agent,
        )
        return SignInResult(user=user, tokens=tokens, was_signup=not existed_before)

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
