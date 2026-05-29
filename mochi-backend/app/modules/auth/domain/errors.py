"""Auth 도메인 에러 — 401/403 응답으로 매핑.

모든 에러는 ``app.core.error_envelope.UnauthorizedError`` 의 자식이거나 ``DomainError`` 로 변환된다.
응답 envelope 의 ``code`` 는 ``auth.<sub>`` 네임스페이스로 통일.
"""

from app.core.error_envelope import DomainError, UnauthorizedError


class InvalidIdTokenError(UnauthorizedError):
    code = "auth.invalid_id_token"


class IdTokenIssuerMismatchError(UnauthorizedError):
    code = "auth.id_token_issuer_mismatch"


class IdTokenAudienceMismatchError(UnauthorizedError):
    code = "auth.id_token_audience_mismatch"


class IdTokenExpiredError(UnauthorizedError):
    code = "auth.id_token_expired"


class IdTokenNonceMismatchError(UnauthorizedError):
    code = "auth.id_token_nonce_mismatch"


class IdTokenEmailUnverifiedError(UnauthorizedError):
    code = "auth.id_token_email_unverified"


class RefreshTokenNotFoundError(UnauthorizedError):
    code = "auth.refresh_not_found"


class RefreshTokenExpiredError(UnauthorizedError):
    code = "auth.refresh_expired"


class RefreshTokenRevokedError(UnauthorizedError):
    code = "auth.refresh_revoked"


class RefreshTokenReuseDetectedError(UnauthorizedError):
    """이미 사용된 refresh token 이 다시 들어왔을 때 — family 전체가 revoke 된다."""

    code = "auth.refresh_reuse_detected"


class UserDeletedError(UnauthorizedError):
    code = "auth.user_deleted"


class AuthAccountRevokedError(UnauthorizedError):
    code = "auth.account_revoked"


class AuthConfigurationError(DomainError):
    """서버 측 잘못된 설정 (e.g. AUTH_ACCESS_SECRET 미설정)."""

    code = "auth.misconfigured"
    status_code = 500
