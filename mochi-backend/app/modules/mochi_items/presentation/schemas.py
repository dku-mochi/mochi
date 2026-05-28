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
    lifecycle_kind: str = Field(alias="lifecycleKind")
    sync_kind: str = Field(alias="syncKind")
    image_refs: list[ImageRefResponse] = Field(default_factory=list, alias="imageRefs")
    captured_at: datetime = Field(alias="capturedAt")
    created_at: datetime = Field(alias="createdAt")

    model_config = {"populate_by_name": True}


class IntentCandidateResponse(BaseModel):
    """알림에 노출되는 LLM 의도 후보 1건."""

    label: str
    intent: Intent
    applicability: float
    reasoning: str


class BackTapMochiItemResponse(BaseModel):
    """백탭 ingestion 응답 — MochiItem 본체 + 사용자에게 보여줄 후보 3개.

    멱등 재요청 (``wasReplay=true``) 시 ``candidates`` 는 빈 리스트로 반환된다.
    저장된 MochiItem 자체에는 LLM 의 원본 후보 reasoning 이 보관되지 않으므로
    재현이 의미를 갖지 않는다.
    """

    item: MochiItemResponse
    candidates: list[IntentCandidateResponse] = Field(default_factory=list)
    was_replay: bool = Field(alias="wasReplay")

    model_config = {"populate_by_name": True}


class IntentOverrideRequest(BaseModel):
    """알림에서 사용자가 다른 primary intent 를 선택했을 때의 PATCH 본문."""

    intent: Intent
