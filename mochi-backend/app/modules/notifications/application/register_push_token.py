from dataclasses import dataclass
from uuid import UUID

from app.modules.notifications.domain.entities import (
    APNsEnvironment,
    DevicePushToken,
    PushTokenType,
)
from app.modules.notifications.domain.ports import PushTokenRepository


@dataclass(frozen=True, slots=True)
class RegisterPushTokenCommand:
    owner_id: UUID
    token: str
    token_type: PushTokenType
    environment: APNsEnvironment
    mochi_item_id: UUID | None = None


class RegisterPushToken:
    """단말/Live Activity push 토큰 등록 (owner-scoped upsert)."""

    def __init__(self, *, tokens: PushTokenRepository) -> None:
        self._tokens = tokens

    async def execute(self, command: RegisterPushTokenCommand) -> None:
        await self._tokens.upsert(
            DevicePushToken(
                owner_id=command.owner_id,
                token=command.token,
                token_type=command.token_type,
                environment=command.environment,
                mochi_item_id=command.mochi_item_id,
            )
        )
