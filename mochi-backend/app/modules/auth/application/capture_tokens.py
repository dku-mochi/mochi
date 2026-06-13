"""Capture-scoped token 발급/검증 use case.

ShareExtension 직접 전송 전용 장수명 자격증명. 정책:

- 발급: access JWT 인증 필수 (라우트 책임). 사용자당 활성 cap 초과 시 oldest-first evict —
  capture token 으로 capture token 을 발급받을 수 없다(스코프 격리, 권한 상승 차단).
- 검증: hash 매칭 → not-found / revoked / expired 분기. 정상이면 sliding 연장
  (``last_used_at`` 기준 1시간 디바운스로 ``expires_at = now + TTL`` 갱신).
- revoke 연쇄: logout(해당 토큰), refresh reuse 감지(사용자 전체 — ``RotateRefreshToken``),
  계정 탈퇴(미래 훅 ``revoke_all_for_user``).
"""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from app.modules.auth.domain.entities import (
    CaptureToken,
    CaptureTokenRevokedReason,
    new_capture_token_id,
)
from app.modules.auth.domain.errors import (
    CaptureTokenExpiredError,
    CaptureTokenNotFoundError,
    CaptureTokenRevokedError,
)
from app.modules.auth.domain.ports import CaptureTokenIssuer, CaptureTokenRepository
from app.shared.ids import UserID

# sliding 연장의 write 디바운스 — 이 간격 안의 재검증은 UPDATE 를 생략한다.
# 180일 TTL 대비 최대 1시간의 연장 누락은 무의미하고, 캡처 폭주 시 row write 폭주를 막는다.
_TOUCH_DEBOUNCE = timedelta(hours=1)


@dataclass(frozen=True, slots=True)
class IssueCaptureTokenCommand:
    user_id: UserID
    device_label: str | None = None


@dataclass(frozen=True, slots=True)
class IssuedCaptureToken:
    """클라이언트에 한 번만 전달되는 raw secret. 이후 어떤 응답에도 재노출되지 않는다."""

    raw_token: str
    expires_at: datetime


class IssueCaptureToken:
    def __init__(
        self,
        *,
        capture_tokens: CaptureTokenRepository,
        issuer: CaptureTokenIssuer,
        max_active: int,
    ) -> None:
        self._capture_tokens = capture_tokens
        self._issuer = issuer
        self._max_active = max_active

    async def execute(self, cmd: IssueCaptureTokenCommand) -> IssuedCaptureToken:
        now = datetime.now(UTC)
        # 발급을 사용자 단위로 직렬화 — list→revoke→add 가 비원자라 동시 발급이 같은
        # active 목록을 보면 cap 을 초과한다 (codex review P2). 트랜잭션 종료 시 자동 해제.
        await self._capture_tokens.acquire_issue_lock(user_id=cmd.user_id)
        # cap-eviction — 디바이스 고유 식별자가 없으므로(iPhone+iPad 멀티디바이스 공존 허용)
        # "재발급 시 기존 revoke" 대신 개수 상한으로 통제한다. Keychain 유실(재설치)로 고아가
        # 된 토큰은 여기서, 또는 sliding 만료로 회수된다.
        active = await self._capture_tokens.list_active_for_user(user_id=cmd.user_id, now=now)
        overflow = len(active) - self._max_active + 1
        for stale in active[: max(overflow, 0)]:
            await self._capture_tokens.revoke(
                token_id=stale.id,
                revoked_at=now,
                reason=CaptureTokenRevokedReason.EVICTED,
            )

        raw, token_hash, expires_at = self._issuer.generate(now=now)
        await self._capture_tokens.add(
            CaptureToken(
                id=new_capture_token_id(),
                user_id=cmd.user_id,
                token_hash=token_hash,
                device_label=cmd.device_label,
                issued_at=now,
                expires_at=expires_at,
            )
        )
        return IssuedCaptureToken(raw_token=raw, expires_at=expires_at)


class VerifyCaptureToken:
    def __init__(
        self,
        *,
        capture_tokens: CaptureTokenRepository,
        issuer: CaptureTokenIssuer,
        ttl_seconds: int,
    ) -> None:
        self._capture_tokens = capture_tokens
        self._issuer = issuer
        self._ttl = timedelta(seconds=ttl_seconds)

    async def execute(self, *, raw_token: str) -> UserID:
        now = datetime.now(UTC)
        token_hash = self._issuer.hash_existing(raw_secret=raw_token)
        current = await self._capture_tokens.find_by_hash(token_hash=token_hash)
        if current is None:
            raise CaptureTokenNotFoundError(
                "Capture token not found",
                code="auth.capture_token_not_found",
            )
        if current.is_revoked:
            raise CaptureTokenRevokedError(
                "Capture token has been revoked",
                code="auth.capture_token_revoked",
            )
        if current.is_expired(now):
            raise CaptureTokenExpiredError(
                "Capture token expired",
                code="auth.capture_token_expired",
            )
        await self._capture_tokens.touch(
            token_id=current.id,
            now=now,
            expires_at=now + self._ttl,
            debounce_cutoff=now - _TOUCH_DEBOUNCE,
        )
        return current.user_id
