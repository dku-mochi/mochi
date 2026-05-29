"""인증 모듈 — 보호 라우트가 사용하는 ``CurrentUser`` 의존성.

검증 순서:
1. ``Authorization: Bearer <token>`` 헤더 필수
2. ``token`` 이 ``dev:<subject>`` 로 시작하면 dev 모드 (environment=local 한정).
   기존 호환을 위해 SHA-256 으로 결정론적 UUID 를 derive 한다 — captures 테스트가 의존.
3. 그 외에는 모찌가 자체 발행한 access JWT (HS256, iss=mochi.app, aud=mochi.app) 로 간주.
   서명/만료/iss/aud/sub 모두 검증 → ``sub`` 의 UUID 를 ``UserID`` 로 반환.

레거시 외부 IdP JWKS 검증은 제거되었다. Apple/Google ID Token 은 ``/auth/{apple,google}``
경로에서만 검증하고, 이후 모든 보호 라우트는 자체 access JWT 만 받는다.
"""

import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header

from app.core.config import get_settings
from app.core.error_envelope import UnauthorizedError
from app.modules.auth.domain.errors import InvalidIdTokenError
from app.modules.auth.infrastructure.providers import get_access_token_issuer
from app.shared.ids import UserID

_DEV_TOKEN_PREFIX = "dev:"


def _derive_dev_user_id(subject: str) -> UserID:
    digest = hashlib.sha256(subject.encode("utf-8")).digest()[:16]
    return UserID(UUID(bytes=digest, version=4))


async def get_current_user(
    authorization: Annotated[str | None, Header()] = None,
) -> UserID:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise UnauthorizedError("Bearer token required", code="auth.missing_token")

    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise UnauthorizedError("Empty token", code="auth.empty_token")

    settings = get_settings()
    if token.startswith(_DEV_TOKEN_PREFIX):
        if settings.environment != "local":
            raise UnauthorizedError(
                "Dev tokens are only valid in local environment",
                code="auth.dev_token_not_allowed_in_env",
            )
        subject = token.removeprefix(_DEV_TOKEN_PREFIX).strip()
        if not subject:
            raise UnauthorizedError(
                "Dev token requires a subject",
                code="auth.dev_token_missing_subject",
            )
        return _derive_dev_user_id(subject)

    issuer = get_access_token_issuer()
    try:
        return issuer.verify(token=token)
    except InvalidIdTokenError as exc:
        # 모든 access JWT 실패는 UnauthorizedError envelope 로 표면화.
        raise UnauthorizedError(exc.message, code=exc.code) from exc


CurrentUser = Annotated[UserID, Depends(get_current_user)]
