from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from app.modules.mochi_items.domain.entities import IngestChannel
from app.shared.intent import Intent


class ImageRefDTO(BaseModel):
    """클라이언트가 업로드한 이미지에 대한 참조.

    실제 바이트는 별도 객체 스토리지 업로드 후 ``object_key`` 로만 전달된다.
    """

    object_key: str | None = Field(default=None, alias="objectKey")
    mime_type: str = Field(alias="mimeType")
    byte_size: int = Field(ge=0, le=50 * 1024 * 1024, alias="byteSize")
    sha256: str = Field(min_length=64, max_length=64)

    model_config = {"populate_by_name": True}


class ImageRefResponse(BaseModel):
    """MochiItem 응답에 포함되는 이미지 참조."""

    object_key: str | None = Field(default=None, alias="objectKey")
    mime_type: str = Field(alias="mimeType")
    byte_size: int = Field(alias="byteSize")
    sha256: str

    model_config = {"populate_by_name": True}


class MochiItemCreateRequest(BaseModel):
    """클라이언트(iOS)가 보내는 MochiItem ingestion payload.

    iOS는 본 스키마와 동일한 모양의 ``MochiItemIngestRequest`` 를 송신한다 — 양쪽이 OpenAPI 로 검증된다.
    """

    channel: IngestChannel
    url: str | None = None
    text: str | None = None
    user_memo: str | None = Field(default=None, alias="userMemo")
    image_refs: list[ImageRefDTO] = Field(default_factory=list, alias="imageRefs")

    model_config = {"populate_by_name": True}


class IntentCandidateResponse(BaseModel):
    """홈 "헷갈려요" 카드·Live Activity 버튼에 노출되는 LLM use case 후보 1건."""

    label: str
    intent: Intent
    applicability: float
    reasoning: str = ""


class MochiItemResponse(BaseModel):
    id: UUID
    channel: IngestChannel
    url: str | None
    text: str | None
    user_memo: str | None = Field(default=None, alias="userMemo")
    intent: Intent
    secondary_intents: list[Intent] = Field(default_factory=list, alias="secondaryIntents")
    intent_applicability: dict[str, float] = Field(
        default_factory=dict, alias="intentApplicability"
    )
    summary: str | None
    importance: int
    confidence: float
    candidates: list[IntentCandidateResponse] = Field(default_factory=list)
    lifecycle_kind: str = Field(alias="lifecycleKind")
    sync_kind: str = Field(alias="syncKind")
    image_refs: list[ImageRefResponse] = Field(default_factory=list, alias="imageRefs")
    captured_at: datetime = Field(alias="capturedAt")
    created_at: datetime = Field(alias="createdAt")

    model_config = {"populate_by_name": True}


class IntentOverrideRequest(BaseModel):
    """알림에서 사용자가 다른 primary intent 를 선택했을 때의 PATCH 본문."""

    intent: Intent


class BackTapMochiItemRequest(BaseModel):
    """백탭 ingestion 요청 — 클라이언트가 Signed URL 로 GCS 에 업로드한 뒤 objectKey 를 보낸다."""

    object_key: str = Field(alias="objectKey")
    sha256: str = Field(min_length=64, max_length=64)
    mime_type: str = Field(alias="mimeType")
    byte_size: int = Field(ge=0, le=50 * 1024 * 1024, alias="byteSize")
    user_memo: str | None = Field(default=None, alias="userMemo")

    model_config = {"populate_by_name": True}


class PresignRequest(BaseModel):
    """캡처 이미지 업로드용 Signed PUT URL 발급 요청."""

    sha256: str = Field(min_length=64, max_length=64)
    mime_type: str = Field(alias="mimeType")

    model_config = {"populate_by_name": True}


class PresignResponse(BaseModel):
    """발급된 V4 Signed PUT URL + 서버가 부여한 object_key."""

    object_key: str = Field(alias="objectKey")
    upload_url: str = Field(alias="uploadURL")
    expires_at: datetime = Field(alias="expiresAt")

    model_config = {"populate_by_name": True}
