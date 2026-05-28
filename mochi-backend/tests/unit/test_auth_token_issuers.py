"""HS256 access JWT 발급/검증 + opaque refresh token 생성/해시 단위 테스트."""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest

from app.core.config import Settings
from app.modules.auth.domain.errors import (
    AuthConfigurationError,
    InvalidIdTokenError,
)
from app.modules.auth.infrastructure.jwt_issuer import HS256AccessTokenIssuer
from app.modules.auth.infrastructure.refresh_issuer import OpaqueRefreshTokenIssuer
from app.shared.ids import UserID


def _make_settings(secret: str = "x" * 64, access_ttl: int = 1800, refresh_ttl: int = 86400 * 30) -> Settings:
    return Settings(
        environment="local",
        auth_access_secret=secret,
        auth_access_ttl_seconds=access_ttl,
        auth_refresh_ttl_seconds=refresh_ttl,
        auth_jwt_issuer="mochi.app",
        auth_jwt_audience="mochi.app",
    )


def test_access_token_issue_and_verify_roundtrip() -> None:
    issuer = HS256AccessTokenIssuer(_make_settings())
    user_id = UserID(uuid4())
    now = datetime.now(UTC)
    token, exp = issuer.issue(user_id=user_id, now=now)
    assert exp > now
    assert issuer.verify(token=token) == user_id


def test_access_token_rejects_short_secret() -> None:
    issuer = HS256AccessTokenIssuer(_make_settings(secret="short"))
    with pytest.raises(AuthConfigurationError):
        issuer.issue(user_id=UserID(uuid4()), now=datetime.now(UTC))


def test_access_token_rejects_alg_none() -> None:
    settings = _make_settings()
    issuer = HS256AccessTokenIssuer(settings)
    # alg=none 토큰을 직접 만들어 거부되는지 확인 (PyJWT 가 algorithms 화이트리스트로 거부)
    payload = {
        "iss": "mochi.app",
        "aud": "mochi.app",
        "sub": str(uuid4()),
        "iat": int(datetime.now(UTC).timestamp()),
        "exp": int((datetime.now(UTC) + timedelta(seconds=1800)).timestamp()),
    }
    bad_token = jwt.encode(payload, key="", algorithm="none")
    with pytest.raises(InvalidIdTokenError):
        issuer.verify(token=bad_token)


def test_access_token_rejects_expired() -> None:
    settings = _make_settings(access_ttl=1)
    issuer = HS256AccessTokenIssuer(settings)
    past = datetime.now(UTC) - timedelta(hours=1)
    token, _ = issuer.issue(user_id=UserID(uuid4()), now=past)
    with pytest.raises(InvalidIdTokenError):
        issuer.verify(token=token)


def test_access_token_rejects_audience_mismatch() -> None:
    settings_a = _make_settings()
    settings_b = _make_settings()
    settings_b.auth_jwt_audience = "other.app"
    issuer_a = HS256AccessTokenIssuer(settings_a)
    issuer_b = HS256AccessTokenIssuer(settings_b)
    token, _ = issuer_a.issue(user_id=UserID(uuid4()), now=datetime.now(UTC))
    with pytest.raises(InvalidIdTokenError):
        issuer_b.verify(token=token)


def test_refresh_token_generate_and_hash_match() -> None:
    issuer = OpaqueRefreshTokenIssuer(_make_settings())
    now = datetime.now(UTC)
    raw, token_hash, exp = issuer.generate(now=now)
    assert len(raw) >= 32
    assert len(token_hash) == 64
    assert exp > now
    # 같은 raw 를 다시 hash 했을 때 동일해야 한다 — 회전 시 hash 매칭 보장.
    assert issuer.hash_existing(raw_secret=raw) == token_hash


def test_refresh_token_each_call_is_unique() -> None:
    issuer = OpaqueRefreshTokenIssuer(_make_settings())
    now = datetime.now(UTC)
    raws = {issuer.generate(now=now)[0] for _ in range(50)}
    assert len(raws) == 50  # 충돌 없음


def test_access_token_rejects_dev_default_secret_in_non_local_env() -> None:
    """codex review P1: prod 에 .env 가 없어 default secret 이 그대로 들어오는 시나리오를 막는다.

    default 가 32+ chars 라 길이 검사로는 못 거른다 → 정확 값 비교로 reject.
    """

    dev_default = "dev-insecure-please-rotate-in-prod-with-openssl-rand-base64-48"
    settings = _make_settings(secret=dev_default)
    settings.environment = "production"
    issuer = HS256AccessTokenIssuer(settings)
    with pytest.raises(AuthConfigurationError):
        issuer.issue(user_id=UserID(uuid4()), now=datetime.now(UTC))


def test_access_token_allows_dev_default_secret_in_local_env() -> None:
    dev_default = "dev-insecure-please-rotate-in-prod-with-openssl-rand-base64-48"
    settings = _make_settings(secret=dev_default)
    settings.environment = "local"
    issuer = HS256AccessTokenIssuer(settings)
    # local 환경에서는 dev 기본값을 그대로 허용 — 개발 흐름 보존.
    token, _ = issuer.issue(user_id=UserID(uuid4()), now=datetime.now(UTC))
    assert token
