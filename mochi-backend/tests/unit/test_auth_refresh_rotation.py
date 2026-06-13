"""RotateRefreshToken + SignIn + Logout use case 의 도메인-레벨 테스트.

in-memory repo + 가짜 verifier 로 DB/Apple/Google 없이 핵심 보안 흐름을 검증한다.
중점:
- 정상 회전: 옛 토큰 used 마크 + 새 토큰 발급 (같은 family, parent 연결)
- reuse detection: used 토큰이 다시 들어오면 family 전체 revoke + 401
- expired: 만료 토큰은 401 (family revoke 는 하지 않음)
- revoked: 이미 revoke 된 토큰은 401
- logout: revoke 정상 동작, idempotent
- SignIn (Apple/Google): 신규 가입 + 재로그인 + display_name backfill
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.modules.auth.application.logout import Logout, LogoutCommand
from app.modules.auth.application.refresh import RefreshCommand, RotateRefreshToken
from app.modules.auth.application.sign_in import (
    AppleSignInCommand,
    GoogleSignInCommand,
    SignIn,
)
from app.modules.auth.domain.entities import (
    AuthAccount,
    AuthProvider,
    CaptureToken,
    CaptureTokenRevokedReason,
    RefreshToken,
    RefreshTokenRevokedReason,
    User,
    VerifiedIdToken,
    new_capture_token_id,
    new_family_id,
    new_refresh_token_id,
)
from app.modules.auth.domain.errors import (
    RefreshTokenExpiredError,
    RefreshTokenNotFoundError,
    RefreshTokenReuseDetectedError,
    RefreshTokenRevokedError,
)
from app.modules.auth.domain.ports import (
    AccessTokenIssuer,
    CaptureTokenIssuer,
    CaptureTokenRepository,
    IdTokenVerifier,
    RefreshTokenIssuer,
    RefreshTokenRepository,
    UserRepository,
)
from app.shared.ids import UserID

# ---------- Fakes ----------


class _InMemoryUsers(UserRepository):
    def __init__(self) -> None:
        self.users: dict[UserID, User] = {}
        self.accounts: dict[tuple[str, str], AuthAccount] = {}

    async def find_account(self, *, provider, subject):
        acc = self.accounts.get((provider.value, subject))
        if acc is None:
            return None
        return acc, self.users[acc.user_id]

    async def find_user(self, *, user_id):
        return self.users.get(user_id)

    async def create_user_and_account(self, *, provider, subject, email, display_name, locale="ko-KR"):
        user_id = UserID(uuid4())
        user = User(id=user_id, email=email.lower(), display_name=display_name, locale=locale)
        account = AuthAccount(
            id=uuid4(),
            user_id=user_id,
            provider=provider,
            subject=subject,
            email_at_link=email.lower(),
            linked_at=datetime.now(UTC),
        )
        self.users[user_id] = user
        self.accounts[(provider.value, subject)] = account
        return user, account

    async def update_display_name_if_empty(self, *, user_id, display_name):
        user = self.users[user_id]
        if not user.display_name:
            user.display_name = display_name

    async def upsert_user_with_id(self, *, user_id, email, display_name, locale="ko-KR"):
        existing = self.users.get(user_id)
        if existing is not None:
            return existing
        user = User(id=user_id, email=email.lower(), display_name=display_name, locale=locale)
        self.users[user_id] = user
        return user


class _InMemoryRefreshTokens(RefreshTokenRepository):
    def __init__(self) -> None:
        self.tokens: dict[UUID, RefreshToken] = {}
        self.by_hash: dict[str, UUID] = {}

    async def add(self, token):
        self.tokens[token.id] = token
        self.by_hash[token.token_hash] = token.id

    async def find_by_hash(self, *, token_hash):
        tid = self.by_hash.get(token_hash)
        return self.tokens.get(tid) if tid else None

    async def mark_used(self, *, token_id, used_at) -> bool:
        token = self.tokens[token_id]
        if token.used_at is None:
            token.used_at = used_at
            return True
        return False

    async def revoke(self, *, token_id, revoked_at, reason):
        token = self.tokens[token_id]
        if token.revoked_at is None:
            token.revoked_at = revoked_at
            token.revoked_reason = reason

    async def revoke_family(self, *, family_id, revoked_at, reason):
        count = 0
        for token in self.tokens.values():
            if token.family_id == family_id and token.revoked_at is None:
                token.revoked_at = revoked_at
                token.revoked_reason = reason
                count += 1
        return count


class _InMemoryCaptureTokens(CaptureTokenRepository):
    def __init__(self) -> None:
        self.tokens: dict[UUID, CaptureToken] = {}
        self.by_hash: dict[str, UUID] = {}

    async def acquire_issue_lock(self, *, user_id):
        pass  # 단일 스레드 테스트 — 직렬화 불필요

    async def add(self, token):
        self.tokens[token.id] = token
        self.by_hash[token.token_hash] = token.id

    async def find_by_hash(self, *, token_hash):
        tid = self.by_hash.get(token_hash)
        return self.tokens.get(tid) if tid else None

    async def list_active_for_user(self, *, user_id, now):
        return sorted(
            (
                t
                for t in self.tokens.values()
                if t.user_id == user_id and t.revoked_at is None and not t.is_expired(now)
            ),
            key=lambda t: t.issued_at,
        )

    async def touch(self, *, token_id, now, expires_at, debounce_cutoff) -> bool:
        token = self.tokens[token_id]
        if token.revoked_at is not None:
            return False
        if token.last_used_at is None or token.last_used_at < debounce_cutoff:
            token.last_used_at = now
            token.expires_at = expires_at
            return True
        return False

    async def revoke(self, *, token_id, revoked_at, reason):
        token = self.tokens[token_id]
        if token.revoked_at is None:
            token.revoked_at = revoked_at
            token.revoked_reason = reason

    async def revoke_all_for_user(self, *, user_id, revoked_at, reason):
        count = 0
        for token in self.tokens.values():
            if token.user_id == user_id and token.revoked_at is None:
                token.revoked_at = revoked_at
                token.revoked_reason = reason
                count += 1
        return count


class _CounterCaptureIssuer(CaptureTokenIssuer):
    """결정론적 raw / hash 생성 — 카운터 기반 (refresh 의 _CounterRefreshIssuer 미러)."""

    def __init__(self) -> None:
        self.counter = 0

    def generate(self, *, now):
        self.counter += 1
        raw = f"mct_raw-{self.counter}"
        return raw, self._hash(raw), now + timedelta(days=180)

    def hash_existing(self, *, raw_secret):
        return self._hash(raw_secret)

    @staticmethod
    def _hash(raw: str) -> str:
        return f"hash::{raw}"


class _FakeAccessIssuer(AccessTokenIssuer):
    def __init__(self) -> None:
        self.issued: list[UserID] = []

    def issue(self, *, user_id, now):
        self.issued.append(user_id)
        return f"access-for-{user_id}-{now.timestamp()}", now + timedelta(seconds=1800)

    def verify(self, *, token):
        raise NotImplementedError


class _CounterRefreshIssuer(RefreshTokenIssuer):
    """결정론적 raw / hash 생성 — 카운터 기반."""

    def __init__(self) -> None:
        self.counter = 0

    def generate(self, *, now):
        self.counter += 1
        raw = f"raw-{self.counter}"
        return raw, self._hash(raw), now + timedelta(days=30)

    def hash_existing(self, *, raw_secret):
        return self._hash(raw_secret)

    @staticmethod
    def _hash(raw: str) -> str:
        # SHA-256 hex 흉내 — 단순 결정론 (테스트만)
        return f"hash::{raw}"


class _StubVerifier(IdTokenVerifier):
    def __init__(self, payload: VerifiedIdToken) -> None:
        self.payload = payload
        self.last_nonce: str | None = None

    async def verify_apple(self, *, id_token, nonce_raw):
        self.last_nonce = nonce_raw
        return self.payload

    async def verify_google(self, *, id_token):
        return self.payload


# ---------- Helpers ----------


def _make_rotate(
    users: _InMemoryUsers,
    refresh: _InMemoryRefreshTokens,
    capture: _InMemoryCaptureTokens | None = None,
) -> RotateRefreshToken:
    return RotateRefreshToken(
        refresh_tokens=refresh,
        users=users,
        access_issuer=_FakeAccessIssuer(),
        refresh_issuer=_CounterRefreshIssuer(),
        capture_tokens=capture or _InMemoryCaptureTokens(),
    )


def _make_signin(
    users: _InMemoryUsers,
    refresh: _InMemoryRefreshTokens,
    verifier: _StubVerifier,
) -> SignIn:
    return SignIn(
        verifier=verifier,
        users=users,
        refresh_tokens=refresh,
        access_issuer=_FakeAccessIssuer(),
        refresh_issuer=_CounterRefreshIssuer(),
    )


async def _seed_user_and_refresh(
    users: _InMemoryUsers,
    refresh: _InMemoryRefreshTokens,
    *,
    family_id: UUID | None = None,
    expires_in_seconds: int = 30 * 86400,
) -> tuple[UserID, RefreshToken]:
    user_id = UserID(uuid4())
    users.users[user_id] = User(id=user_id, email="u@mochi.app", display_name="u")
    now = datetime.now(UTC)
    token = RefreshToken(
        id=new_refresh_token_id(),
        user_id=user_id,
        token_hash="hash::raw-0",
        family_id=family_id or new_family_id(),
        parent_id=None,
        device_label=None,
        user_agent=None,
        issued_at=now,
        expires_at=now + timedelta(seconds=expires_in_seconds),
    )
    await refresh.add(token)
    return user_id, token


# ---------- Refresh rotation ----------


@pytest.mark.asyncio
async def test_refresh_rotation_happy_path_marks_old_used_and_issues_new() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    _, old = await _seed_user_and_refresh(users, refresh)

    use_case = _make_rotate(users, refresh)
    tokens = await use_case.execute(RefreshCommand(raw_refresh_token="raw-0"))

    # 옛 토큰 used 마크 (but not revoked)
    assert refresh.tokens[old.id].used_at is not None
    assert refresh.tokens[old.id].revoked_at is None

    # 새 토큰: 같은 family + parent=old + raw 새로움
    new_tokens = [t for t in refresh.tokens.values() if t.id != old.id]
    assert len(new_tokens) == 1
    new_token = new_tokens[0]
    assert new_token.family_id == old.family_id
    assert new_token.parent_id == old.id
    assert new_token.token_hash != old.token_hash
    assert tokens.refresh_token == "raw-1"
    assert "access-for-" in tokens.access_token


@pytest.mark.asyncio
async def test_refresh_unknown_token_returns_401() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    use_case = _make_rotate(users, refresh)
    with pytest.raises(RefreshTokenNotFoundError):
        await use_case.execute(RefreshCommand(raw_refresh_token="raw-unknown"))


@pytest.mark.asyncio
async def test_refresh_reuse_detected_revokes_whole_family() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    user_id, old = await _seed_user_and_refresh(users, refresh)
    capture = _InMemoryCaptureTokens()
    now = datetime.now(UTC)
    await capture.add(
        CaptureToken(
            id=new_capture_token_id(),
            user_id=user_id,
            token_hash="hash::mct_raw-x",
            device_label=None,
            issued_at=now,
            expires_at=now + timedelta(days=180),
        )
    )
    use_case = _make_rotate(users, refresh, capture)

    # 첫 회전 → 정상
    await use_case.execute(RefreshCommand(raw_refresh_token="raw-0"))

    # 같은 raw-0 를 또 사용 → reuse_detected
    with pytest.raises(RefreshTokenReuseDetectedError):
        await use_case.execute(RefreshCommand(raw_refresh_token="raw-0"))

    # family 전체가 revoke 되었는지 확인 (옛것 + 회전된 새것 모두)
    for token in refresh.tokens.values():
        assert token.revoked_at is not None
        assert token.revoked_reason == RefreshTokenRevokedReason.REUSE_DETECTED

    # 도난 의심 시 같은 사용자의 장수명 capture token 도 연쇄 revoke — 도주로 차단.
    for ct in capture.tokens.values():
        assert ct.revoked_at is not None
        assert ct.revoked_reason == CaptureTokenRevokedReason.REUSE_DETECTED


@pytest.mark.asyncio
async def test_refresh_expired_token_returns_401_without_family_revoke() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    _, old = await _seed_user_and_refresh(users, refresh, expires_in_seconds=-10)
    use_case = _make_rotate(users, refresh)
    with pytest.raises(RefreshTokenExpiredError):
        await use_case.execute(RefreshCommand(raw_refresh_token="raw-0"))
    # 만료는 도난과 다르다 — family 는 그대로 둔다.
    assert refresh.tokens[old.id].revoked_at is None


@pytest.mark.asyncio
async def test_refresh_revoked_token_returns_401() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    _, old = await _seed_user_and_refresh(users, refresh)
    await refresh.revoke(
        token_id=old.id,
        revoked_at=datetime.now(UTC),
        reason=RefreshTokenRevokedReason.LOGOUT,
    )
    use_case = _make_rotate(users, refresh)
    with pytest.raises(RefreshTokenRevokedError):
        await use_case.execute(RefreshCommand(raw_refresh_token="raw-0"))


# ---------- Logout ----------


@pytest.mark.asyncio
async def test_logout_revokes_token_and_is_idempotent() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    _, old = await _seed_user_and_refresh(users, refresh)
    logout = Logout(
        refresh_tokens=refresh,
        refresh_issuer=_CounterRefreshIssuer(),
        capture_tokens=_InMemoryCaptureTokens(),
        capture_issuer=_CounterCaptureIssuer(),
    )
    await logout.execute(LogoutCommand(raw_refresh_token="raw-0"))
    assert refresh.tokens[old.id].revoked_reason == RefreshTokenRevokedReason.LOGOUT

    # 두 번 호출해도 조용히 성공
    await logout.execute(LogoutCommand(raw_refresh_token="raw-0"))
    await logout.execute(LogoutCommand(raw_refresh_token="raw-unknown"))


# ---------- Sign-in ----------


@pytest.mark.asyncio
async def test_apple_signin_creates_new_user_and_passes_raw_nonce_to_verifier() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    verifier = _StubVerifier(
        VerifiedIdToken(
            provider=AuthProvider.APPLE,
            subject="apple-001",
            email="user@example.com",
            email_verified=True,
        )
    )
    use_case = _make_signin(users, refresh, verifier)
    result = await use_case.with_apple(
        AppleSignInCommand(
            id_token="dummy",
            nonce_raw="my-nonce",
            full_name="송준서",
        )
    )
    assert result.was_signup is True
    assert verifier.last_nonce == "my-nonce"
    assert result.user.display_name == "송준서"
    # refresh 1개, 새 family
    assert len(refresh.tokens) == 1


@pytest.mark.asyncio
async def test_apple_signin_reuses_existing_user_by_subject() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    verifier = _StubVerifier(
        VerifiedIdToken(
            provider=AuthProvider.APPLE,
            subject="apple-001",
            email="user@example.com",
            email_verified=True,
        )
    )
    use_case = _make_signin(users, refresh, verifier)
    first = await use_case.with_apple(AppleSignInCommand(id_token="t", nonce_raw=None, full_name="A"))
    second = await use_case.with_apple(AppleSignInCommand(id_token="t", nonce_raw=None, full_name=None))
    assert second.user.id == first.user.id
    assert second.was_signup is False


@pytest.mark.asyncio
async def test_apple_signin_backfills_display_name_when_initially_empty() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    verifier = _StubVerifier(
        VerifiedIdToken(
            provider=AuthProvider.APPLE,
            subject="apple-002",
            email="x@example.com",
            email_verified=True,
        )
    )
    use_case = _make_signin(users, refresh, verifier)
    first = await use_case.with_apple(AppleSignInCommand(id_token="t", nonce_raw=None, full_name=None))
    assert first.user.display_name == ""
    second = await use_case.with_apple(
        AppleSignInCommand(id_token="t", nonce_raw=None, full_name="박세현")
    )
    assert second.user.display_name == "박세현"


@pytest.mark.asyncio
async def test_google_signin_uses_id_token_name_as_display_hint() -> None:
    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    verifier = _StubVerifier(
        VerifiedIdToken(
            provider=AuthProvider.GOOGLE,
            subject="google-123",
            email="g@example.com",
            email_verified=True,
            name="이용찬",
        )
    )
    use_case = _make_signin(users, refresh, verifier)
    result = await use_case.with_google(GoogleSignInCommand(id_token="t"))
    assert result.user.display_name == "이용찬"
    assert result.was_signup is True


# ---------- Codex review follow-ups ----------


@pytest.mark.asyncio
async def test_signin_with_unverified_email_uses_placeholder_not_real_address() -> None:
    """codex review P2: email_verified=false 인 IdP 토큰의 이메일을 그대로 저장하면 안 된다.

    공격자가 다른 사용자의 실 이메일을 unverified 상태로 보내 ``users.email UNIQUE`` 를 선점할 수 있다.
    """

    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    verifier = _StubVerifier(
        VerifiedIdToken(
            provider=AuthProvider.GOOGLE,
            subject="attacker-001",
            email="victim@example.com",
            email_verified=False,
        )
    )
    use_case = _make_signin(users, refresh, verifier)
    result = await use_case.with_google(GoogleSignInCommand(id_token="t"))
    assert result.user.email != "victim@example.com"
    assert "unset.mochi.local" in result.user.email


@pytest.mark.asyncio
async def test_concurrent_refresh_only_one_wins_other_triggers_reuse_detection() -> None:
    """codex review P1: 동시 회전 race 에서 진 호출은 새 자식 토큰을 발급해선 안 된다.

    ``mark_used`` 가 ``where used_at IS NULL`` atomic compare-and-set 으로 1번만 성공한다.
    진 호출은 ``False`` 를 받아 reuse_detected 분기로 들어가고, family 전체가 revoke 된다.
    """

    users = _InMemoryUsers()
    refresh = _InMemoryRefreshTokens()
    _, old = await _seed_user_and_refresh(users, refresh)

    # 같은 raw 를 받아 race 를 시뮬레이션 — 한 use_case 인스턴스의 ``mark_used`` 가 먼저 통과되도록
    # InMemory 가 직렬화하므로, 두 번째 호출은 곧장 used_at != None 으로 빠진다.
    a = _make_rotate(users, refresh)
    b = _make_rotate(users, refresh)
    tokens_a = await a.execute(RefreshCommand(raw_refresh_token="raw-0"))
    assert tokens_a.refresh_token == "raw-1"

    with pytest.raises(RefreshTokenReuseDetectedError):
        await b.execute(RefreshCommand(raw_refresh_token="raw-0"))

    # family 전체가 revoke 되었는지 확인 — 옛 토큰 + 회전된 새 토큰 모두.
    for token in refresh.tokens.values():
        assert token.revoked_at is not None
        assert token.revoked_reason == RefreshTokenRevokedReason.REUSE_DETECTED
