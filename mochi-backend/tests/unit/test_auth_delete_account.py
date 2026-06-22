"""DeleteAccount use case 도메인 테스트.

검증 포인트:
- 계정을 soft delete(``mark_deleted``) 한다.
- 장수명 capture token 을 ``USER_ACCOUNT_DELETED`` 사유로 전부 revoke 한다.
"""

from uuid import uuid4

import pytest

from app.modules.auth.application.delete_account import (
    DeleteAccount,
    DeleteAccountCommand,
)
from app.modules.auth.domain.entities import CaptureTokenRevokedReason


class _FakeUsers:
    def __init__(self) -> None:
        self.deleted: dict = {}

    async def mark_deleted(self, *, user_id, deleted_at) -> None:
        self.deleted[user_id] = deleted_at


class _FakeCaptureTokens:
    def __init__(self) -> None:
        self.revoked: list = []

    async def revoke_all_for_user(self, *, user_id, revoked_at, reason) -> int:
        self.revoked.append((user_id, reason))
        return 2


@pytest.mark.asyncio
async def test_delete_account_soft_deletes_and_revokes_capture_tokens() -> None:
    users = _FakeUsers()
    captures = _FakeCaptureTokens()
    use_case = DeleteAccount(users=users, capture_tokens=captures)
    user_id = uuid4()

    await use_case.execute(DeleteAccountCommand(user_id=user_id))

    assert user_id in users.deleted
    assert captures.revoked == [(user_id, CaptureTokenRevokedReason.USER_ACCOUNT_DELETED)]
