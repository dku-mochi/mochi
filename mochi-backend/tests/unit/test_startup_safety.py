"""부팅 시 auth fail-open 차단 가드(`_verify_startup_safety`) 단위 테스트.

핵심 위협: 실사용자가 붙는 배포가 ENVIRONMENT 누락으로 `local` 로 떠서 dev 토큰·dev sign-in·
well-known dev secret 이 모두 열리는 완전한 auth bypass. 가드가 부팅에서 이를 막는지 검증한다.
"""

import pytest

from app.core.config import Settings
from app.main import _verify_startup_safety
from app.modules.auth.domain.errors import AuthConfigurationError

_DEV_DEFAULT = "dev-insecure-please-rotate-in-prod-with-openssl-rand-base64-48"
_REAL_SECRET = "x" * 48


def test_local_with_dev_default_secret_boots() -> None:
    # 순수 로컬 개발 — dev 기본 secret + local. 부팅 허용(경고만).
    _verify_startup_safety(Settings(environment="local", auth_access_secret=_DEV_DEFAULT))


def test_local_with_real_secret_refused() -> None:
    # ENVIRONMENT 누락으로 보이는 운영 배포 — local + 운영용 secret. 부팅 거부.
    with pytest.raises(RuntimeError):
        _verify_startup_safety(Settings(environment="local", auth_access_secret=_REAL_SECRET))


def test_production_with_dev_default_refused() -> None:
    # 운영인데 dev 기본 secret — 위조 가능. 즉시 거부(첫 로그인까지 미루지 않음).
    with pytest.raises(AuthConfigurationError):
        _verify_startup_safety(Settings(environment="production", auth_access_secret=_DEV_DEFAULT))


def test_production_with_real_secret_boots() -> None:
    # 올바른 운영 설정 — 부팅 허용.
    _verify_startup_safety(Settings(environment="production", auth_access_secret=_REAL_SECRET))


def test_short_secret_refused() -> None:
    # 32자 미만 secret — environment 무관 거부.
    with pytest.raises(AuthConfigurationError):
        _verify_startup_safety(Settings(environment="production", auth_access_secret="tooshort"))


def test_empty_secret_refused() -> None:
    # 빈 secret — environment 무관 거부(`not secret` 분기).
    with pytest.raises(AuthConfigurationError):
        _verify_startup_safety(Settings(environment="local", auth_access_secret=""))


def test_environment_uppercase_normalized_boots() -> None:
    # "Local" 오타 — 정규화로 local 게이트가 일관 동작, dev 기본 secret 부팅 허용(부팅 거부되는 DX 함정 방지).
    _verify_startup_safety(Settings(environment="Local", auth_access_secret=_DEV_DEFAULT))


def test_environment_trailing_space_normalized_boots() -> None:
    # 공백 포함 — 정규화로 local 로 취급되어 부팅 허용.
    _verify_startup_safety(Settings(environment=" local ", auth_access_secret=_DEV_DEFAULT))
