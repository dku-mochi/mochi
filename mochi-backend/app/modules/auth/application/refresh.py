"""Refresh token rotation + reuse detection use case.

이 use case 는 ``POST /auth/refresh`` 의 핵심 보안 경계다. 정책:

- 정상: token_hash 매칭 + revoked/expired/used 모두 아님
  → ``used_at = now`` 마크 + 새 RefreshToken INSERT (같은 family, parent=current)
  → 새 access JWT 발행
- 비정상 1) hash 매칭 실패 → ``RefreshTokenNotFoundError``
- 비정상 2) 이미 revoked → ``RefreshTokenRevokedError``
- 비정상 3) 이미 used (도난 의심) → family 전체 revoke + ``RefreshTokenReuseDetectedError``
- 비정상 4) expired → ``RefreshTokenExpiredError``
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.modules.auth.domain.entities import (
    AuthTokens,
    CaptureTokenRevokedReason,
    RefreshToken,
    RefreshTokenRevokedReason,
    new_refresh_token_id,
)
from app.modules.auth.domain.errors import (
    RefreshTokenExpiredError,
    RefreshTokenNotFoundError,
    RefreshTokenReuseDetectedError,
    RefreshTokenRevokedError,
    UserDeletedError,
)
from app.modules.auth.domain.ports import (
    AccessTokenIssuer,
    CaptureTokenRepository,
    RefreshTokenIssuer,
    RefreshTokenRepository,
    UserRepository,
)


@dataclass(frozen=True, slots=True)
class RefreshCommand:
    raw_refresh_token: str
    device_label: str | None = None
    user_agent: str | None = None


class RotateRefreshToken:
    def __init__(
        self,
        *,
        refresh_tokens: RefreshTokenRepository,
        users: UserRepository,
        access_issuer: AccessTokenIssuer,
        refresh_issuer: RefreshTokenIssuer,
        capture_tokens: CaptureTokenRepository,
    ) -> None:
        # capture_tokens 는 reuse 감지 시 연쇄 revoke 보안 훅 — optional 로 두면 배선 누락이
        # 조용히 훅을 무력화하므로 의도적으로 필수 주입이다.
        self._refresh_tokens = refresh_tokens
        self._users = users
        self._access_issuer = access_issuer
        self._refresh_issuer = refresh_issuer
        self._capture_tokens = capture_tokens

    async def execute(self, cmd: RefreshCommand) -> AuthTokens:
        now = datetime.now(UTC)
        token_hash = self._refresh_issuer.hash_existing(raw_secret=cmd.raw_refresh_token)
        current = await self._refresh_tokens.find_by_hash(token_hash=token_hash)
        if current is None:
            raise RefreshTokenNotFoundError(
                "Refresh token not found",
                code="auth.refresh_not_found",
            )

        if current.is_revoked:
            raise RefreshTokenRevokedError(
                "Refresh token has been revoked",
                code="auth.refresh_revoked",
            )

        if current.is_used:
            # 도난 의심 — family 전체를 revoke 하고 사용자에게 재로그인 강제.
            # 같은 사용자의 capture token 도 전부 revoke 한다 — 장수명 자격증명을 살려두면
            # 도난자의 도주로가 된다. 다른 디바이스 ShareExt 는 큐 폴백으로 유실 없이 저하,
            # 앱 재부팅(재로그인) 시 재발급된다. 보안 > 편의.
            await self._refresh_tokens.revoke_family(
                family_id=current.family_id,
                revoked_at=now,
                reason=RefreshTokenRevokedReason.REUSE_DETECTED,
            )
            await self._capture_tokens.revoke_all_for_user(
                user_id=current.user_id,
                revoked_at=now,
                reason=CaptureTokenRevokedReason.REUSE_DETECTED,
            )
            raise RefreshTokenReuseDetectedError(
                "Refresh token reuse detected; family revoked",
                code="auth.refresh_reuse_detected",
            )

        if current.is_expired(now):
            # 만료 토큰은 revoke 까지 갈 필요 없음 — 그냥 401.
            raise RefreshTokenExpiredError(
                "Refresh token expired",
                code="auth.refresh_expired",
            )

        user = await self._users.find_user(user_id=current.user_id)
        if user is None or user.deleted_at is not None:
            raise UserDeletedError("User no longer exists", code="auth.user_deleted")

        # 정상 회전 — 옛 토큰 사용 마크 **먼저**. 같은 토큰을 동시에 회전하려는 경쟁 호출이 있어도
        # DB 의 ``where(used_at IS NULL)`` atomic update 가 1번만 성공한다. 진 호출은 ``False`` 를
        # 받고 곧장 reuse_detected 분기로 진입 — 새 자식 토큰을 발급하지 않는다.
        won = await self._refresh_tokens.mark_used(token_id=current.id, used_at=now)
        if not won:
            await self._refresh_tokens.revoke_family(
                family_id=current.family_id,
                revoked_at=now,
                reason=RefreshTokenRevokedReason.REUSE_DETECTED,
            )
            await self._capture_tokens.revoke_all_for_user(
                user_id=current.user_id,
                revoked_at=now,
                reason=CaptureTokenRevokedReason.REUSE_DETECTED,
            )
            raise RefreshTokenReuseDetectedError(
                "Refresh token rotation race detected; family revoked",
                code="auth.refresh_reuse_detected",
            )

        raw_new, hash_new, exp_new = self._refresh_issuer.generate(now=now)
        await self._refresh_tokens.add(
            RefreshToken(
                id=new_refresh_token_id(),
                user_id=current.user_id,
                token_hash=hash_new,
                family_id=current.family_id,
                parent_id=current.id,
                device_label=cmd.device_label or current.device_label,
                user_agent=cmd.user_agent or current.user_agent,
                issued_at=now,
                expires_at=exp_new,
            )
        )
        access, access_exp = self._access_issuer.issue(user_id=current.user_id, now=now)
        return AuthTokens(
            access_token=access,
            access_token_expires_at=access_exp,
            refresh_token=raw_new,
            refresh_token_expires_at=exp_new,
        )
