"""Apple/Google ID Token verifier 단위 테스트.

RSA 키 페어를 즉석으로 생성 → 가짜 JWKS 응답 → JWT 서명 → verifier 가 검증·거부 하는지 확인.
"""

import hashlib
import json
from datetime import UTC, datetime, timedelta

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.core.config import Settings
from app.modules.auth.domain.entities import AuthProvider
from app.modules.auth.domain.errors import (
    IdTokenAudienceMismatchError,
    IdTokenExpiredError,
    IdTokenIssuerMismatchError,
    IdTokenNonceMismatchError,
    InvalidIdTokenError,
)
from app.modules.auth.infrastructure.id_token_verifier import HttpxIdTokenVerifier


def _gen_rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _public_jwk(private_key, kid: str) -> dict:
    # JWK 표현은 PyJWT 의 RSAAlgorithm.to_jwk 사용 (public-only).
    from jwt.algorithms import RSAAlgorithm

    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    jwk_json = RSAAlgorithm.to_jwk(
        jwt.algorithms.RSAAlgorithm.from_jwk(
            json.dumps({"kty": "RSA", "kid": kid, **_n_e_from_pem(public_pem)})  # type: ignore[arg-type]
        )
    )
    obj = json.loads(jwk_json)
    obj["kid"] = kid
    obj["alg"] = "RS256"
    obj["use"] = "sig"
    return obj


def _n_e_from_pem(pem: bytes) -> dict:
    """RSA public PEM → base64url(n), base64url(e). PyJWT 가 알아서 처리하기에 우회 헬퍼."""
    from cryptography.hazmat.primitives.serialization import load_pem_public_key

    public_key = load_pem_public_key(pem)
    numbers = public_key.public_numbers()  # type: ignore[attr-defined]
    import base64

    def _b64(n: int) -> str:
        size = (n.bit_length() + 7) // 8
        return base64.urlsafe_b64encode(n.to_bytes(size, "big")).rstrip(b"=").decode("ascii")

    return {"n": _b64(numbers.n), "e": _b64(numbers.e)}


def _sign(private_key, claims: dict, kid: str) -> str:
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return jwt.encode(claims, pem, algorithm="RS256", headers={"kid": kid})


def _settings(**overrides) -> Settings:
    base = dict(
        environment="local",
        auth_access_secret="x" * 64,
        auth_apple_audience="app.mochi",
        auth_apple_jwks_url="https://appleid.apple.com/auth/keys",
        auth_apple_issuer="https://appleid.apple.com",
        auth_google_client_ids="ios-client.apps.googleusercontent.com",
        auth_google_jwks_url="https://www.googleapis.com/oauth2/v3/certs",
    )
    base.update(overrides)
    return Settings(**base)


def _mock_jwks_transport(jwks: dict) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=jwks)

    return httpx.MockTransport(handler)


@pytest.mark.asyncio
async def test_apple_id_token_happy_path() -> None:
    pk = _gen_rsa_key()
    kid = "apple-kid-1"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    nonce_raw = "client-generated-nonce"
    hashed_nonce = hashlib.sha256(nonce_raw.encode()).hexdigest()
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "app.mochi",
        "sub": "apple-user-001",
        "email": "u@example.com",
        "email_verified": "true",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
        "nonce": hashed_nonce,
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        verified = await verifier.verify_apple(id_token=token, nonce_raw=nonce_raw)
    assert verified.provider == AuthProvider.APPLE
    assert verified.subject == "apple-user-001"
    assert verified.email == "u@example.com"
    assert verified.email_verified is True


@pytest.mark.asyncio
async def test_apple_id_token_rejects_wrong_nonce() -> None:
    pk = _gen_rsa_key()
    kid = "k"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "app.mochi",
        "sub": "u",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
        "nonce": hashlib.sha256(b"server-expected").hexdigest(),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenNonceMismatchError):
            await verifier.verify_apple(id_token=token, nonce_raw="client-sent-this")


@pytest.mark.asyncio
async def test_apple_id_token_rejects_token_without_nonce() -> None:
    # nonce claim 이 없는(=nonce 미바인딩) 유효 서명 토큰은 거부해야 한다. 과거엔 검증을 건너뛰어
    # nonce-less victim identityToken 의 replay(계정 탈취)가 가능했다. raw nonce 유무와 무관하게 거부.
    pk = _gen_rsa_key()
    kid = "k"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "app.mochi",
        "sub": "u",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
        # nonce 의도적 누락
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenNonceMismatchError):
            await verifier.verify_apple(id_token=token, nonce_raw="client-sent-this")
        with pytest.raises(IdTokenNonceMismatchError):
            await verifier.verify_apple(id_token=token, nonce_raw=None)


@pytest.mark.asyncio
async def test_apple_id_token_rejects_wrong_issuer() -> None:
    pk = _gen_rsa_key()
    kid = "k"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://evil.example.com",
        "aud": "app.mochi",
        "sub": "u",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenIssuerMismatchError):
            await verifier.verify_apple(id_token=token, nonce_raw=None)


@pytest.mark.asyncio
async def test_apple_id_token_rejects_wrong_audience() -> None:
    pk = _gen_rsa_key()
    kid = "k"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "com.other.bundle",
        "sub": "u",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenAudienceMismatchError):
            await verifier.verify_apple(id_token=token, nonce_raw=None)


@pytest.mark.asyncio
async def test_apple_id_token_rejects_expired() -> None:
    pk = _gen_rsa_key()
    kid = "k"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    past = datetime.now(UTC) - timedelta(hours=2)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "app.mochi",
        "sub": "u",
        "iat": int(past.timestamp()),
        "exp": int((past + timedelta(minutes=10)).timestamp()),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenExpiredError):
            await verifier.verify_apple(id_token=token, nonce_raw=None)


@pytest.mark.asyncio
async def test_apple_id_token_rejects_alg_none() -> None:
    # alg=none 으로 자체 위조 — kid 가 없어도 verifier 가 alg 화이트리스트로 거부해야 한다.
    now = datetime.now(UTC)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": "app.mochi",
        "sub": "u",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
    }
    forged = jwt.encode(claims, key="", algorithm="none")
    async with httpx.AsyncClient(transport=_mock_jwks_transport({"keys": []})) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(InvalidIdTokenError):
            await verifier.verify_apple(id_token=forged, nonce_raw=None)


@pytest.mark.asyncio
async def test_google_id_token_happy_path() -> None:
    pk = _gen_rsa_key()
    kid = "google-kid"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://accounts.google.com",
        "aud": "ios-client.apps.googleusercontent.com",
        "sub": "1234567890",
        "email": "g@example.com",
        "email_verified": True,
        "name": "Google User",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        verified = await verifier.verify_google(id_token=token)
    assert verified.provider == AuthProvider.GOOGLE
    assert verified.subject == "1234567890"
    assert verified.name == "Google User"


@pytest.mark.asyncio
async def test_google_id_token_rejects_unknown_audience() -> None:
    pk = _gen_rsa_key()
    kid = "google-kid"
    jwks = {"keys": [_public_jwk(pk, kid)]}
    now = datetime.now(UTC)
    claims = {
        "iss": "https://accounts.google.com",
        "aud": "attacker.apps.googleusercontent.com",
        "sub": "x",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=10)).timestamp()),
    }
    token = _sign(pk, claims, kid)
    async with httpx.AsyncClient(transport=_mock_jwks_transport(jwks)) as client:
        verifier = HttpxIdTokenVerifier(_settings(), http_client=client)
        with pytest.raises(IdTokenAudienceMismatchError):
            await verifier.verify_google(id_token=token)


@pytest.mark.asyncio
async def test_google_id_token_rejects_when_no_client_ids_configured() -> None:
    # AUTH_GOOGLE_CLIENT_IDS 비어있으면 검증 자체가 misconfigured 로 거부되어야 한다.
    settings = _settings(auth_google_client_ids="")
    async with httpx.AsyncClient(transport=_mock_jwks_transport({"keys": []})) as client:
        verifier = HttpxIdTokenVerifier(settings, http_client=client)
        with pytest.raises(InvalidIdTokenError):
            await verifier.verify_google(id_token="any.thing.here")
