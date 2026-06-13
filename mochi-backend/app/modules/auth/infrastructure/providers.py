"""Module-level singletons — verifier 와 issuer 의 lazy 인스턴스.

verifier 는 httpx client + JWKS cache 를 들고 있어 매 요청 새로 만들면 비효율.
issuer 는 stateless 지만 settings 를 들고 있어 같은 패턴으로 통일.
"""

from functools import lru_cache

from app.core.config import Settings, get_settings
from app.modules.auth.infrastructure.capture_token_issuer import OpaqueCaptureTokenIssuer
from app.modules.auth.infrastructure.id_token_verifier import HttpxIdTokenVerifier
from app.modules.auth.infrastructure.jwt_issuer import HS256AccessTokenIssuer
from app.modules.auth.infrastructure.refresh_issuer import OpaqueRefreshTokenIssuer


@lru_cache(maxsize=1)
def get_id_token_verifier(settings: Settings | None = None) -> HttpxIdTokenVerifier:
    return HttpxIdTokenVerifier(settings or get_settings())


@lru_cache(maxsize=1)
def get_access_token_issuer(settings: Settings | None = None) -> HS256AccessTokenIssuer:
    return HS256AccessTokenIssuer(settings or get_settings())


@lru_cache(maxsize=1)
def get_refresh_token_issuer(settings: Settings | None = None) -> OpaqueRefreshTokenIssuer:
    return OpaqueRefreshTokenIssuer(settings or get_settings())


@lru_cache(maxsize=1)
def get_capture_token_issuer(settings: Settings | None = None) -> OpaqueCaptureTokenIssuer:
    return OpaqueCaptureTokenIssuer(settings or get_settings())


def reset_providers_for_tests() -> None:
    """테스트 헬퍼 — settings 가 바뀐 뒤 캐시를 비우고 싶을 때만 호출."""

    get_id_token_verifier.cache_clear()
    get_access_token_issuer.cache_clear()
    get_refresh_token_issuer.cache_clear()
    get_capture_token_issuer.cache_clear()
