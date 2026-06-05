"""notifications 모듈 도메인 엔티티 — 디바이스/Live Activity push 토큰 + 알림 표현.

프레임워크 import 금지(httpx/jwt/cryptography 는 infrastructure 한정 — 모듈 경계테스트).
"""

from dataclasses import dataclass
from enum import StrEnum
from uuid import UUID


class PushTokenType(StrEnum):
    """등록되는 푸시 토큰의 종류.

    - ``apns_device``: 단말 remote notification 토큰 (owner 1:N 단말). 분석완료 alert 대상.
    - ``live_activity``: ActivityKit Live Activity push 토큰 (mochi_item 1:1). .ready 전환 대상.
    """

    APNS_DEVICE = "apns_device"
    LIVE_ACTIVITY = "live_activity"


class APNsEnvironment(StrEnum):
    """device token 이 묶인 APNs 환경. 잘못 매칭 시 BadDeviceToken.

    TestFlight/App Store = production, Xcode 직접 빌드 = sandbox.
    """

    SANDBOX = "sandbox"
    PRODUCTION = "production"


class APNsPushType(StrEnum):
    """APNs ``apns-push-type`` 헤더 값."""

    ALERT = "alert"
    LIVEACTIVITY = "liveactivity"


@dataclass(frozen=True, slots=True)
class DevicePushToken:
    """등록된 푸시 토큰 1건 (owner-scoped)."""

    owner_id: UUID
    token: str
    token_type: PushTokenType
    environment: APNsEnvironment
    mochi_item_id: UUID | None = None
