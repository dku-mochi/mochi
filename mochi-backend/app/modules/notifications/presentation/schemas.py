"""POST /devices/push-token 의 Pydantic 스키마. iOS DTO 와 1:1, camelCase alias."""

from uuid import UUID

from pydantic import BaseModel, Field

from app.modules.notifications.domain.entities import APNsEnvironment, PushTokenType


class RegisterPushTokenRequest(BaseModel):
    """단말(apns_device) 또는 Live Activity(live_activity) push 토큰 등록 요청."""

    token: str = Field(min_length=1, max_length=512)
    token_type: PushTokenType = Field(alias="tokenType")
    # 클라(iOS)가 자기 빌드 환경을 명시한다 — Xcode=sandbox, TestFlight/App Store=production.
    # 토큰은 환경에 묶여 잘못 매칭 시 BadDeviceToken → required(서버 기본값 없음).
    environment: APNsEnvironment
    mochi_item_id: UUID | None = Field(default=None, alias="mochiItemID")

    model_config = {"populate_by_name": True}
