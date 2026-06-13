"""Logout — refresh token revoke (+ 동봉된 capture token revoke).

access JWT 자체는 short-TTL(30분) 이라 blacklist 없이도 만료 후 자연 무효화된다.
의도적으로 단순화: refresh 만 revoke. 정밀 무효화가 필요해지면 access JTI blacklist 추가.

capture token 은 장수명이라 자연 무효화에 기댈 수 없다 — 클라이언트가 logout 요청에
raw capture token 을 동봉하면 해당 토큰만 revoke 한다(멀티디바이스의 다른 토큰은 유지).
두 revoke 는 각각 idempotent 하고 서로 독립이다 (refresh 가 이미 사라졌어도 capture 는 처리).
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.modules.auth.domain.entities import (
    CaptureTokenRevokedReason,
    RefreshTokenRevokedReason,
)
from app.modules.auth.domain.ports import (
    CaptureTokenIssuer,
    CaptureTokenRepository,
    RefreshTokenIssuer,
    RefreshTokenRepository,
)


@dataclass(frozen=True, slots=True)
class LogoutCommand:
    raw_refresh_token: str
    raw_capture_token: str | None = None


class Logout:
    def __init__(
        self,
        *,
        refresh_tokens: RefreshTokenRepository,
        refresh_issuer: RefreshTokenIssuer,
        capture_tokens: CaptureTokenRepository,
        capture_issuer: CaptureTokenIssuer,
    ) -> None:
        self._refresh_tokens = refresh_tokens
        self._refresh_issuer = refresh_issuer
        self._capture_tokens = capture_tokens
        self._capture_issuer = capture_issuer

    async def execute(self, cmd: LogoutCommand) -> None:
        now = datetime.now(UTC)

        token_hash = self._refresh_issuer.hash_existing(raw_secret=cmd.raw_refresh_token)
        current = await self._refresh_tokens.find_by_hash(token_hash=token_hash)
        if current is not None and not current.is_revoked:
            await self._refresh_tokens.revoke(
                token_id=current.id,
                revoked_at=now,
                reason=RefreshTokenRevokedReason.LOGOUT,
            )

        if cmd.raw_capture_token:
            capture_hash = self._capture_issuer.hash_existing(raw_secret=cmd.raw_capture_token)
            capture = await self._capture_tokens.find_by_hash(token_hash=capture_hash)
            if capture is not None and not capture.is_revoked:
                await self._capture_tokens.revoke(
                    token_id=capture.id,
                    revoked_at=now,
                    reason=CaptureTokenRevokedReason.LOGOUT,
                )
