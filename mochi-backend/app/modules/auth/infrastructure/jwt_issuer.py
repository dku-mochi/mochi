"""자체 발행 access JWT (HS256) — PyJWT 기반 ``AccessTokenIssuer`` 구현."""

from datetime import datetime, timedelta
from uuid import UUID, uuid4

import jwt

from app.core.config import Settings
from app.modules.auth.domain.errors import (
    AuthConfigurationError,
    InvalidIdTokenError,
)
from app.modules.auth.domain.ports import AccessTokenIssuer
from app.shared.ids import UserID


class HS256AccessTokenIssuer(AccessTokenIssuer):
    """HS256 single-secret JWT. single-instance backend 에 충분.

    multi-region/multi-instance 가 되면 RS256 + JWKS 로 전환 — 본 클래스 교체로 끝남.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    # Settings 의 default 값. environment != local 에서 이 값이 그대로 들어오면 즉시 거부 —
    # 그렇지 않으면 운영에 ``.env`` 가 없을 때 누구나 위조 가능한 well-known secret 으로 JWT 가 서명된다.
    _DEV_DEFAULT_SECRET = "dev-insecure-please-rotate-in-prod-with-openssl-rand-base64-48"

    def _resolve_secret(self) -> str:
        secret = self._settings.auth_access_secret
        if not secret or len(secret) < 32:
            raise AuthConfigurationError(
                "AUTH_ACCESS_SECRET must be set to 32+ chars",
                code="auth.misconfigured",
            )
        if self._settings.environment != "local" and secret == self._DEV_DEFAULT_SECRET:
            raise AuthConfigurationError(
                "AUTH_ACCESS_SECRET is the built-in dev default; rotate it in non-local environments",
                code="auth.misconfigured_default_secret",
            )
        return secret

    def issue(self, *, user_id: UserID, now: datetime) -> tuple[str, datetime]:
        expires_at = now + timedelta(seconds=self._settings.auth_access_ttl_seconds)
        claims = {
            "iss": self._settings.auth_jwt_issuer,
            "aud": self._settings.auth_jwt_audience,
            "sub": str(user_id),
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
            "jti": uuid4().hex,
        }
        token = jwt.encode(claims, self._resolve_secret(), algorithm="HS256")
        return token, expires_at

    def verify(self, *, token: str) -> UserID:
        try:
            claims = jwt.decode(
                token,
                self._resolve_secret(),
                algorithms=["HS256"],
                audience=self._settings.auth_jwt_audience,
                issuer=self._settings.auth_jwt_issuer,
                options={"require": ["exp", "iat", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise InvalidIdTokenError(
                f"Access JWT invalid: {exc}",
                code="auth.access_invalid",
            ) from exc

        subject = claims.get("sub")
        if not subject:
            raise InvalidIdTokenError("Access JWT has no sub", code="auth.access_invalid")
        try:
            return UserID(UUID(subject))
        except (TypeError, ValueError) as exc:
            raise InvalidIdTokenError(
                "Access JWT sub is not a valid UUID",
                code="auth.access_invalid",
            ) from exc

    # Borrowing for fakes — exposed only for tests in this package.
    def _decode_unverified(self, token: str) -> dict:  # pragma: no cover - debug only
        return jwt.decode(token, options={"verify_signature": False})
