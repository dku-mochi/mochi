"""notifications 모듈 outbound port (Hexagonal).

application 은 이 추상 인터페이스만 의존하고 infrastructure 가 구현한다.
domain 은 httpx/jwt/cryptography 어떤 외부 패키지도 import 하지 않는다.
"""

from abc import ABC, abstractmethod
from typing import Any
from uuid import UUID

from app.modules.notifications.domain.entities import (
    APNsEnvironment,
    APNsPushType,
    DevicePushToken,
    PushTokenType,
)


class APNsClient(ABC):
    """APNs HTTP/2 전송 추상화 (단일 POST /3/device/{token})."""

    @abstractmethod
    async def send(
        self,
        *,
        token: str,
        environment: APNsEnvironment,
        push_type: APNsPushType,
        topic: str,
        payload: dict[str, Any],
        collapse_id: str | None = None,
    ) -> None:
        """전송 실패 시 예외를 raise 한다 (호출부 best-effort 격리 책임)."""


class PushTokenRepository(ABC):
    """``device_push_tokens`` 영속화. 모든 메서드는 ``owner_id`` 로 cross-tenant 차단."""

    @abstractmethod
    async def upsert(self, token: DevicePushToken) -> None:
        """``(owner_id, token_type, token)`` 유니크로 upsert (환경·item 갱신)."""

    @abstractmethod
    async def list_for_owner(
        self, *, owner_id: UUID, token_type: PushTokenType
    ) -> list[DevicePushToken]: ...

    @abstractmethod
    async def list_live_activity_for_item(
        self, *, owner_id: UUID, mochi_item_id: UUID
    ) -> list[DevicePushToken]: ...
