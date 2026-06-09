"""notifications 모듈 도메인 엔티티 — 디바이스/Live Activity push 토큰 + 알림 표현.

프레임워크 import 금지(httpx/jwt/cryptography 는 infrastructure 한정 — 모듈 경계테스트).
"""

from dataclasses import dataclass
from enum import StrEnum
from uuid import UUID


class PushTokenType(StrEnum):
    """등록되는 푸시 토큰의 종류.

    - ``apns_device``: 단말 remote notification 토큰 (owner 1:N 단말). 분석완료 alert 대상.
    - ``la_start``: Live Activity push-to-start 토큰 (owner 1:N 단말, item 무관). needs_review=true
      분석완료 시 백엔드가 이 토큰으로 LA 를 background(잠금)에서 시작한다(start push). iOS 17.2+.
      진행중/완료 LA 는 띄우지 않는다(팀 결정 2026-06-09) — 구 per-item ``live_activity`` 토큰 폐기.
    """

    APNS_DEVICE = "apns_device"
    LA_START = "la_start"


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
