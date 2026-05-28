"""POST /auth/* + GET /users/me 의 Pydantic 스키마.

iOS DTO 와 1:1. camelCase alias 유지.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class AppleSignInRequest(BaseModel):
    id_token: str = Field(alias="identityToken", min_length=10)
    raw_nonce: str | None = Field(default=None, alias="rawNonce")
    full_name: str | None = Field(default=None, alias="fullName", max_length=128)
    device_label: str | None = Field(default=None, alias="deviceLabel", max_length=128)

    model_config = {"populate_by_name": True}


class GoogleSignInRequest(BaseModel):
    id_token: str = Field(alias="idToken", min_length=10)
    device_label: str | None = Field(default=None, alias="deviceLabel", max_length=128)

    model_config = {"populate_by_name": True}


class RefreshRequest(BaseModel):
    refresh_token: str = Field(alias="refreshToken", min_length=10)
    device_label: str | None = Field(default=None, alias="deviceLabel", max_length=128)

    model_config = {"populate_by_name": True}


class LogoutRequest(BaseModel):
    refresh_token: str = Field(alias="refreshToken", min_length=10)

    model_config = {"populate_by_name": True}


class DevSignInRequest(BaseModel):
    """Local-only 임시 로그인 요청. ``subject`` 가 user 식별자 역할."""

    subject: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_\-.]+$")
    display_name: str | None = Field(default=None, alias="displayName", max_length=128)
    device_label: str | None = Field(default=None, alias="deviceLabel", max_length=128)

    model_config = {"populate_by_name": True}


class UserResponse(BaseModel):
    id: UUID
    email: str
    display_name: str = Field(alias="displayName")
    locale: str
    onboarding_completed_at: datetime | None = Field(default=None, alias="onboardingCompletedAt")

    model_config = {"populate_by_name": True}


class TokensResponse(BaseModel):
    access_token: str = Field(alias="accessToken")
    access_token_expires_at: datetime = Field(alias="accessTokenExpiresAt")
    refresh_token: str = Field(alias="refreshToken")
    refresh_token_expires_at: datetime = Field(alias="refreshTokenExpiresAt")
    token_type: str = Field(default="Bearer", alias="tokenType")

    model_config = {"populate_by_name": True}


class SignInResponse(BaseModel):
    user: UserResponse
    tokens: TokensResponse
    is_new_user: bool = Field(alias="isNewUser")

    model_config = {"populate_by_name": True}
