"""Logout — refresh token revoke.

access JWT 자체는 short-TTL(30분) 이라 blacklist 없이도 만료 후 자연 무효화된다.
의도적으로 단순화: refresh 만 revoke. 정밀 무효화가 필요해지면 access JTI blacklist 추가.
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.modules.auth.domain.entities import RefreshTokenRevokedReason
from app.modules.auth.domain.ports import RefreshTokenIssuer, RefreshTokenRepository


@dataclass(frozen=True, slots=True)
class LogoutCommand:
    raw_refresh_token: str


class Logout:
    def __init__(
        self,
        *,
        refresh_tokens: RefreshTokenRepository,
        refresh_issuer: RefreshTokenIssuer,
    ) -> None:
        self._refresh_tokens = refresh_tokens
        self._refresh_issuer = refresh_issuer

    async def execute(self, cmd: LogoutCommand) -> None:
        token_hash = self._refresh_issuer.hash_existing(raw_secret=cmd.raw_refresh_token)
        current = await self._refresh_tokens.find_by_hash(token_hash=token_hash)
        if current is None or current.is_revoked:
            return  # idempotent: 이미 사라졌거나 revoke 된 토큰에 대해선 조용히 성공
        await self._refresh_tokens.revoke(
            token_id=current.id,
            revoked_at=datetime.now(UTC),
            reason=RefreshTokenRevokedReason.LOGOUT,
        )
