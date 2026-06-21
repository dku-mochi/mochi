"""DevSignIn use case 의 도메인-레벨 테스트.

검증 포인트:
- 같은 subject 두 번 → 첫 번째는 was_signup=True, 두 번째는 False (멱등).
- ``derive_dev_user_id`` 와 ``app.core.security._derive_dev_user_id`` 가 같은 UUID 를 만든다 — 기존 dev 토큰 흐름 호환.
- 매 호출마다 새 access + refresh 토큰이 발급된다.
"""

import pytest

from app.core.security import _derive_dev_user_id
from app.modules.auth.application.dev_sign_in import (
    DevSignIn,
    DevSignInCommand,
    derive_dev_user_id,
)
from tests.unit.test_auth_refresh_rotation import (
    _CounterRefreshIssuer,
    _FakeAccessIssuer,
    _InMemoryRefreshTokens,
    _InMemoryUsers,
)


def _make() -> tuple[DevSignIn, _InMemoryUsers, _InMemoryRefreshTokens]:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    use_case = DevSignIn(
        users=users,
        refresh_tokens=refresh,
        access_issuer=_FakeAccessIssuer(),
        refresh_issuer=_CounterRefreshIssuer(),
    )
    return use_case, users, refresh


def test_derive_dev_user_id_matches_security_helper() -> None:
    # 같은 subject 면 어디서 derive 하든 동일한 UserID 가 나와야 한다 —
    # 기존 ``Bearer dev:jun`` 토큰으로 만들어진 captures 데이터와 호환.
    assert derive_dev_user_id("jun") == _derive_dev_user_id("jun")
    assert derive_dev_user_id("alice") == _derive_dev_user_id("alice")
    assert derive_dev_user_id("jun") != derive_dev_user_id("alice")


@pytest.mark.asyncio
async def test_dev_sign_in_first_call_is_signup() -> None:
    use_case, users, _ = _make()
    result = await use_case.execute(DevSignInCommand(subject="jun"))
    assert result.was_signup is True
    assert result.user.id == derive_dev_user_id("jun")
    assert result.user.email == "dev-jun@dev.mochi.local"
    assert result.user.display_name == "jun"
    assert len(users.users) == 1


@pytest.mark.asyncio
async def test_dev_sign_in_idempotent_for_same_subject() -> None:
    use_case, users, refresh = _make()
    first = await use_case.execute(DevSignInCommand(subject="jun"))
    second = await use_case.execute(DevSignInCommand(subject="jun"))

    assert first.user.id == second.user.id
    assert first.was_signup is True
    assert second.was_signup is False
    assert len(users.users) == 1
    # 매번 새 refresh family — 디바이스마다 분리되도록.
    assert len(refresh.tokens) == 2


@pytest.mark.asyncio
async def test_dev_sign_in_display_name_override() -> None:
    use_case, _, _ = _make()
    result = await use_case.execute(DevSignInCommand(subject="jun", display_name="준 (테스트)"))
    assert result.user.display_name == "준 (테스트)"
