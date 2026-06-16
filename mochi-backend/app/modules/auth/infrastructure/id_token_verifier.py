"""Apple / Google ID Token 검증 — ``IdTokenVerifier`` 구현.

검증 원칙:
- JWT alg 는 RS256/ES256 만 허용 (Apple/Google 공식 알고리즘). ``none`` / ``HS*`` 거부.
- iss/aud/exp/iat 모두 강제.
- Apple: SHA-256(rawNonce) == claims['nonce'] (iOS 가 보낸 raw 와 비교).
- Google: ``aud`` 가 settings 의 client_ids 화이트리스트 중 하나여야 함.

JWKS 는 in-memory TTL 캐시 (default 10분). 키 회전을 대비해 만료 후 재요청.

PyJWT 의 ``PyJWKClient`` 는 동기여서 asyncio 흐름과 어울리지 않는다.
대신 httpx 로 JWKS 를 비동기 fetch 한 뒤 ``jwt.algorithms.RSAAlgorithm.from_jwk`` 로 키 변환.
"""

import hashlib
import time
from typing import Any

import httpx
import jwt
from jwt.algorithms import ECAlgorithm, RSAAlgorithm

from app.core.config import Settings
from app.modules.auth.domain.entities import AuthProvider, VerifiedIdToken
from app.modules.auth.domain.errors import (
    IdTokenAudienceMismatchError,
    IdTokenExpiredError,
    IdTokenIssuerMismatchError,
    IdTokenNonceMismatchError,
    InvalidIdTokenError,
)
from app.modules.auth.domain.ports import IdTokenVerifier

_ALLOWED_ALGS = ("RS256", "ES256")
_JWKS_CACHE_TTL = 600  # 10분
# iat/nbf/exp 클럭 스큐 허용 — 서버 시계가 Apple/Google 발급 시각보다 수 초 느리면
# 방금 발급된 토큰의 iat 이 미래가 돼 "not yet valid" 로 거부된다(ID token 검증 표준 관행).
_CLOCK_SKEW_LEEWAY = 60  # 초


class _JwksCache:
    """url → (jwks_dict, expires_at_monotonic).

    process-local 캐시. 단일 인스턴스라면 충분. multi-instance 가 되면 Redis 등으로 외부화.
    """

    def __init__(self) -> None:
        self._cache: dict[str, tuple[dict[str, Any], float]] = {}

    async def get(self, url: str, *, http_client: httpx.AsyncClient) -> dict[str, Any]:
        now = time.monotonic()
        cached = self._cache.get(url)
        if cached and cached[1] > now:
            return cached[0]
        response = await http_client.get(url, timeout=5.0)
        response.raise_for_status()
        jwks: dict[str, Any] = response.json()
        self._cache[url] = (jwks, now + _JWKS_CACHE_TTL)
        return jwks

    def clear(self) -> None:
        self._cache.clear()


def _signing_key_from_jwk(jwk: dict[str, Any]) -> Any:
    kty = jwk.get("kty")
    if kty == "RSA":
        return RSAAlgorithm.from_jwk(jwk)
    if kty == "EC":
        return ECAlgorithm.from_jwk(jwk)
    raise InvalidIdTokenError(f"Unsupported JWK kty: {kty}", code="auth.id_token_unsupported_kty")


def _find_jwk(jwks: dict[str, Any], kid: str | None) -> dict[str, Any]:
    keys: list[dict[str, Any]] = jwks.get("keys", [])
    if kid is None:
        if len(keys) == 1:
            return keys[0]
        raise InvalidIdTokenError("kid required when JWKS has multiple keys", code="auth.id_token_kid_missing")
    for key in keys:
        if key.get("kid") == kid:
            return key
    raise InvalidIdTokenError(f"kid not found in JWKS: {kid}", code="auth.id_token_kid_not_found")


class HttpxIdTokenVerifier(IdTokenVerifier):
    """Apple/Google 모두 처리하는 단일 verifier. 모듈 인스턴스 1개로 충분."""

    def __init__(
        self,
        settings: Settings,
        *,
        http_client: httpx.AsyncClient | None = None,
        jwks_cache: _JwksCache | None = None,
    ) -> None:
        self._settings = settings
        self._http = http_client or httpx.AsyncClient()
        self._jwks = jwks_cache or _JwksCache()
        self._owns_http = http_client is None

    async def aclose(self) -> None:
        if self._owns_http:
            await self._http.aclose()

    # ---------- Apple ----------

    async def verify_apple(self, *, id_token: str, nonce_raw: str | None) -> VerifiedIdToken:
        claims = await self._decode(
            id_token=id_token,
            jwks_url=self._settings.auth_apple_jwks_url,
            expected_audiences=(self._settings.auth_apple_audience,),
            expected_issuers=(self._settings.auth_apple_issuer,),
        )

        # Apple nonce 검증: identityToken 의 nonce 는 SHA-256(rawNonce) 의 HEX.
        # iOS 는 raw nonce 를 생성·전달하므로, 서버가 동일한 해시를 만들어 비교한다.
        token_nonce = claims.get("nonce")
        if token_nonce is not None:
            if nonce_raw is None:
                raise IdTokenNonceMismatchError(
                    "Apple ID token carries nonce but client did not send raw nonce",
                    code="auth.id_token_nonce_missing",
                )
            expected = hashlib.sha256(nonce_raw.encode("utf-8")).hexdigest()
            if not _constant_time_eq(expected, token_nonce):
                raise IdTokenNonceMismatchError(
                    "Apple nonce mismatch", code="auth.id_token_nonce_mismatch"
                )

        return VerifiedIdToken(
            provider=AuthProvider.APPLE,
            subject=str(claims["sub"]),
            email=_str_or_none(claims.get("email")),
            # Apple 은 email_verified 를 "true"/"false" 문자열로 보내기도 한다.
            email_verified=_truthy(claims.get("email_verified")),
        )

    # ---------- Google ----------

    async def verify_google(self, *, id_token: str) -> VerifiedIdToken:
        allowed_auds = self._settings.auth_google_client_id_list
        if not allowed_auds:
            raise InvalidIdTokenError(
                "AUTH_GOOGLE_CLIENT_IDS not configured",
                code="auth.misconfigured",
            )
        claims = await self._decode(
            id_token=id_token,
            jwks_url=self._settings.auth_google_jwks_url,
            expected_audiences=allowed_auds,
            expected_issuers=self._settings.auth_google_issuers,
        )
        return VerifiedIdToken(
            provider=AuthProvider.GOOGLE,
            subject=str(claims["sub"]),
            email=_str_or_none(claims.get("email")),
            email_verified=_truthy(claims.get("email_verified")),
            name=_str_or_none(claims.get("name")),
        )

    # ---------- Shared ----------

    async def _decode(
        self,
        *,
        id_token: str,
        jwks_url: str,
        expected_audiences: tuple[str, ...],
        expected_issuers: tuple[str, ...],
    ) -> dict[str, Any]:
        try:
            unverified_header = jwt.get_unverified_header(id_token)
        except jwt.PyJWTError as exc:
            raise InvalidIdTokenError(
                f"Malformed ID token: {exc}", code="auth.id_token_malformed"
            ) from exc

        alg = unverified_header.get("alg")
        if alg not in _ALLOWED_ALGS:
            raise InvalidIdTokenError(
                f"Disallowed JWT alg: {alg}", code="auth.id_token_alg_not_allowed"
            )
        kid = unverified_header.get("kid")

        jwks = await self._jwks.get(jwks_url, http_client=self._http)
        try:
            jwk = _find_jwk(jwks, kid)
        except InvalidIdTokenError:
            # 키 회전 직후일 수 있다. 캐시 무효화 후 1회 재시도.
            self._jwks.clear()
            jwks = await self._jwks.get(jwks_url, http_client=self._http)
            jwk = _find_jwk(jwks, kid)

        signing_key = _signing_key_from_jwk(jwk)

        try:
            claims = jwt.decode(
                id_token,
                signing_key,
                algorithms=list(_ALLOWED_ALGS),
                audience=list(expected_audiences),
                leeway=_CLOCK_SKEW_LEEWAY,
                # PyJWT 는 iss 의 list 비교를 직접 지원하지 않으므로 수동 검증.
                options={"require": ["exp", "iat", "sub"], "verify_iss": False},
            )
        except jwt.ExpiredSignatureError as exc:
            raise IdTokenExpiredError("ID token expired", code="auth.id_token_expired") from exc
        except jwt.InvalidAudienceError as exc:
            raise IdTokenAudienceMismatchError(
                f"Audience mismatch (expected one of {expected_audiences})",
                code="auth.id_token_audience_mismatch",
            ) from exc
        except jwt.PyJWTError as exc:
            raise InvalidIdTokenError(
                f"ID token verification failed: {exc}", code="auth.id_token_invalid"
            ) from exc

        if claims.get("iss") not in expected_issuers:
            raise IdTokenIssuerMismatchError(
                f"Issuer mismatch: {claims.get('iss')}",
                code="auth.id_token_issuer_mismatch",
            )
        return claims


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() == "true"
    return False


def _str_or_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _constant_time_eq(a: str, b: str) -> bool:
    import hmac

    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))
