"""IssueCaptureToken + VerifyCaptureToken + 스코프 격리의 도메인-레벨 테스트.

in-memory repo 로 DB 없이 핵심 보안 흐름을 검증한다. 중점:
- 발급: raw 는 ``mct_`` prefix, 저장은 hash 만, 만료 = now + TTL
- cap-eviction: 활성 cap 초과 발급 시 oldest-first ``evicted`` revoke
- 검증: 정상 → user_id / 미존재·revoked·만료 → 401 계열
- sliding: 검증 시 ``expires_at`` 연장 + 1시간 디바운스 (연속 검증은 write 생략)
- logout: 동봉된 capture token revoke, idempotent, refresh 부재와 독립
- 스코프 격리: ``mct_`` 토큰을 일반 라우트 의존성(``get_current_user``)에 보내면 401
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.core.error_envelope import UnauthorizedError
from app.core.security import get_current_user
from app.modules.auth.application.capture_tokens import (
    IssueCaptureToken,
    IssueCaptureTokenCommand,
    VerifyCaptureToken,
)
from app.modules.auth.application.logout import Logout, LogoutCommand
from app.modules.auth.domain.entities import (
    CAPTURE_TOKEN_PREFIX,
    CaptureToken,
    CaptureTokenRevokedReason,
    new_capture_token_id,
)
from app.modules.auth.domain.errors import (
    CaptureTokenExpiredError,
    CaptureTokenNotFoundError,
    CaptureTokenRevokedError,
)
from app.modules.auth.domain.ports import (
    CaptureTokenIssuer,
    CaptureTokenRepository,
    RefreshTokenIssuer,
    RefreshTokenRepository,
)
from app.shared.ids import UserID

_TTL_SECONDS = 60 * 60 * 24 * 180


# ---------- Fakes ----------


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
    """결정론적 raw / hash 생성 — 카운터 기반. raw 는 실제 prefix 규약을 따른다."""

    def __init__(self) -> None:
        self.counter = 0

    def generate(self, *, now):
        self.counter += 1
        raw = f"{CAPTURE_TOKEN_PREFIX}raw-{self.counter}"
        return raw, self._hash(raw), now + timedelta(seconds=_TTL_SECONDS)

    def hash_existing(self, *, raw_secret):
        return self._hash(raw_secret)

    @staticmethod
    def _hash(raw: str) -> str:
        return f"hash::{raw}"


class _NoopRefreshTokens(RefreshTokenRepository):
    """logout 테스트용 — refresh 쪽은 비어 있어도 capture revoke 가 독립 동작해야 한다."""

    async def add(self, token):
        raise NotImplementedError

    async def find_by_hash(self, *, token_hash):
        return None

    async def mark_used(self, *, token_id, used_at) -> bool:
        raise NotImplementedError

    async def revoke(self, *, token_id, revoked_at, reason):
        raise NotImplementedError

    async def revoke_family(self, *, family_id, revoked_at, reason):
        raise NotImplementedError


class _PassthroughRefreshIssuer(RefreshTokenIssuer):
    def generate(self, *, now):
        raise NotImplementedError

    def hash_existing(self, *, raw_secret):
        return f"hash::{raw_secret}"


# ---------- Helpers ----------


def _make_issue(
    capture: _InMemoryCaptureTokens,
    issuer: _CounterCaptureIssuer,
    *,
    max_active: int = 5,
) -> IssueCaptureToken:
    return IssueCaptureToken(capture_tokens=capture, issuer=issuer, max_active=max_active)


def _make_verify(
    capture: _InMemoryCaptureTokens,
    issuer: _CounterCaptureIssuer,
) -> VerifyCaptureToken:
    return VerifyCaptureToken(capture_tokens=capture, issuer=issuer, ttl_seconds=_TTL_SECONDS)


async def _seed_token(
    capture: _InMemoryCaptureTokens,
    *,
    user_id: UserID | None = None,
    raw: str = f"{CAPTURE_TOKEN_PREFIX}raw-seed",
    expires_in_seconds: int = _TTL_SECONDS,
) -> tuple[UserID, CaptureToken, str]:
    uid = user_id or UserID(uuid4())
    now = datetime.now(UTC)
    token = CaptureToken(
        id=new_capture_token_id(),
        user_id=uid,
        token_hash=f"hash::{raw}",
        device_label=None,
        issued_at=now,
        expires_at=now + timedelta(seconds=expires_in_seconds),
    )
    await capture.add(token)
    return uid, token, raw


# ---------- 발급 ----------


@pytest.mark.asyncio
async def test_issue_returns_prefixed_raw_and_stores_only_hash() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    user_id = UserID(uuid4())

    issued = await _make_issue(capture, issuer).execute(
        IssueCaptureTokenCommand(user_id=user_id, device_label="iOS 26.0")
    )

    assert issued.raw_token.startswith(CAPTURE_TOKEN_PREFIX)
    stored = list(capture.tokens.values())
    assert len(stored) == 1
    assert stored[0].token_hash == f"hash::{issued.raw_token}"
    assert stored[0].user_id == user_id
    assert stored[0].device_label == "iOS 26.0"
    # raw 는 어디에도 저장되지 않는다
    assert issued.raw_token not in {t.token_hash for t in capture.tokens.values()}
    # 만료 = 발급 시점 + TTL (sliding 의 시작점)
    assert issued.expires_at > datetime.now(UTC) + timedelta(seconds=_TTL_SECONDS - 60)


@pytest.mark.asyncio
async def test_issue_evicts_oldest_when_cap_exceeded() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    user_id = UserID(uuid4())
    use_case = _make_issue(capture, issuer, max_active=2)

    first = await use_case.execute(IssueCaptureTokenCommand(user_id=user_id))
    second = await use_case.execute(IssueCaptureTokenCommand(user_id=user_id))
    third = await use_case.execute(IssueCaptureTokenCommand(user_id=user_id))

    by_hash = {t.token_hash: t for t in capture.tokens.values()}
    assert by_hash[f"hash::{first.raw_token}"].revoked_reason == CaptureTokenRevokedReason.EVICTED
    assert by_hash[f"hash::{second.raw_token}"].revoked_at is None
    assert by_hash[f"hash::{third.raw_token}"].revoked_at is None


@pytest.mark.asyncio
async def test_issue_does_not_evict_other_users_tokens() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    other_id, other_token, _ = await _seed_token(capture)
    use_case = _make_issue(capture, issuer, max_active=1)

    await use_case.execute(IssueCaptureTokenCommand(user_id=UserID(uuid4())))

    assert capture.tokens[other_token.id].revoked_at is None


# ---------- 검증 ----------


@pytest.mark.asyncio
async def test_verify_returns_user_id_for_valid_token() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    user_id, _, raw = await _seed_token(capture)

    assert await _make_verify(capture, issuer).execute(raw_token=raw) == user_id


@pytest.mark.asyncio
async def test_verify_unknown_token_raises_not_found() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    with pytest.raises(CaptureTokenNotFoundError):
        await _make_verify(capture, issuer).execute(raw_token=f"{CAPTURE_TOKEN_PREFIX}unknown")


@pytest.mark.asyncio
async def test_verify_revoked_token_raises_revoked() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    _, token, raw = await _seed_token(capture)
    await capture.revoke(
        token_id=token.id,
        revoked_at=datetime.now(UTC),
        reason=CaptureTokenRevokedReason.LOGOUT,
    )
    with pytest.raises(CaptureTokenRevokedError):
        await _make_verify(capture, issuer).execute(raw_token=raw)


@pytest.mark.asyncio
async def test_verify_expired_token_raises_expired() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    _, _, raw = await _seed_token(capture, expires_in_seconds=-10)
    with pytest.raises(CaptureTokenExpiredError):
        await _make_verify(capture, issuer).execute(raw_token=raw)


@pytest.mark.asyncio
async def test_verify_extends_expiry_sliding_with_debounce() -> None:
    capture = _InMemoryCaptureTokens()
    issuer = _CounterCaptureIssuer()
    # 만료까지 1일 남은 토큰 — 검증이 sliding 으로 TTL 전체를 다시 채워야 한다.
    _, token, raw = await _seed_token(capture, expires_in_seconds=86400)
    verify = _make_verify(capture, issuer)

    await verify.execute(raw_token=raw)
    extended = capture.tokens[token.id].expires_at
    assert extended > datetime.now(UTC) + timedelta(seconds=_TTL_SECONDS - 60)
    first_used = capture.tokens[token.id].last_used_at
    assert first_used is not None

    # 디바운스 — 직후 재검증은 write 를 생략한다 (last_used_at·expires_at 불변).
    await verify.execute(raw_token=raw)
    assert capture.tokens[token.id].last_used_at == first_used
    assert capture.tokens[token.id].expires_at == extended


# ---------- Logout 연동 ----------


@pytest.mark.asyncio
async def test_logout_revokes_bundled_capture_token_and_is_idempotent() -> None:
    capture = _InMemoryCaptureTokens()
    _, token, raw = await _seed_token(capture)
    logout = Logout(
        refresh_tokens=_NoopRefreshTokens(),
        refresh_issuer=_PassthroughRefreshIssuer(),
        capture_tokens=capture,
        capture_issuer=_CounterCaptureIssuer(),
    )

    # refresh 토큰이 이미 사라진 상태여도 capture revoke 는 독립 동작
    await logout.execute(LogoutCommand(raw_refresh_token="gone", raw_capture_token=raw))
    assert capture.tokens[token.id].revoked_reason == CaptureTokenRevokedReason.LOGOUT

    # 두 번 호출해도 조용히 성공 (idempotent) — capture 미동봉도 무해
    await logout.execute(LogoutCommand(raw_refresh_token="gone", raw_capture_token=raw))
    await logout.execute(LogoutCommand(raw_refresh_token="gone"))


# ---------- 스코프 격리 ----------


@pytest.mark.asyncio
async def test_capture_token_is_rejected_by_general_route_dependency() -> None:
    """capture token 을 ingest/presign 외 라우트에 보내면 401.

    일반 라우트의 ``get_current_user`` 는 ``mct_`` 토큰을 JWT 로 해석하다 서명 검증에
    실패한다 — 스코프 격리가 별도 차단 코드 없이 성립함을 고정하는 테스트.
    """
    with pytest.raises(UnauthorizedError):
        await get_current_user(authorization=f"Bearer {CAPTURE_TOKEN_PREFIX}stolen-or-misrouted")


def test_capture_scope_is_exactly_ingest_and_presign() -> None:
    """capture token 수용 라우트 집합을 구조적으로 고정한다 (codex review P2).

    누군가 다른 라우트의 ``CurrentUser`` 를 ``CurrentCaptureUser`` 로 바꾸면(스코프 확장)
    이 테스트가 즉시 깨진다. FastAPI 라우트의 의존성 트리를 재귀 순회해 검사한다.
    """
    from fastapi.routing import APIRoute

    from app.core.security import get_current_capture_user
    from app.main import app

    def uses_capture_dependency(dependant) -> bool:
        if dependant.call is get_current_capture_user:
            return True
        return any(uses_capture_dependency(sub) for sub in dependant.dependencies)

    capture_routes = {
        f"{sorted(route.methods)[0]} {route.path}"
        for route in app.routes
        if isinstance(route, APIRoute) and uses_capture_dependency(route.dependant)
    }
    assert capture_routes == {
        "POST /api/v1/mochi_items",
        "POST /api/v1/mochi_items/presign",
    }
