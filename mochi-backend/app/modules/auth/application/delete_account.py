"""DeleteAccount — 회원 탈퇴(계정 삭제).

soft delete(``deleted_at``) + 장수명 capture token 전부 revoke. access JWT 인증 필수.
이후 sign-in/refresh 가 ``deleted_at`` 을 거부해 모든 세션이 자연 무효화된다
(refresh 는 단주기 + 거부, access 는 short-TTL 만료). Apple Sign-in 토큰의 IdP 측 revoke 는
후속 과제(App Review 권고, TODO §5).
"""

from dataclasses import dataclass
from datetime import UTC, datetime

from app.modules.auth.domain.entities import CaptureTokenRevokedReason
from app.modules.auth.domain.ports import CaptureTokenRepository, UserRepository
from app.shared.ids import UserID


@dataclass(frozen=True, slots=True)
class DeleteAccountCommand:
    user_id: UserID


class DeleteAccount:
    def __init__(
        self,
        *,
        users: UserRepository,
        capture_tokens: CaptureTokenRepository,
    ) -> None:
        self._users = users
        self._capture_tokens = capture_tokens

    async def execute(self, cmd: DeleteAccountCommand) -> None:
        now = datetime.now(UTC)
        await self._users.mark_deleted(user_id=cmd.user_id, deleted_at=now)
        await self._capture_tokens.revoke_all_for_user(
            user_id=cmd.user_id,
            revoked_at=now,
            reason=CaptureTokenRevokedReason.USER_ACCOUNT_DELETED,
        )
