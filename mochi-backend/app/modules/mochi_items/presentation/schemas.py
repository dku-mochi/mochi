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


class IntentPayloadResponse(BaseModel):
    """instance 의 구조화 속성 (전부 optional)."""

    title: str | None = None
    date: str | None = None
    time: str | None = None
    deadline: str | None = None
    person: str | None = None
    topic: str | None = None
    url: str | None = None
    note: str | None = None


class IntentInstanceResponse(BaseModel):
    """저장된 의도 instance 1건 — 곧 active. 점수/위계 없음."""

    intent_type: Intent = Field(alias="intentType")
    payload: IntentPayloadResponse = Field(default_factory=IntentPayloadResponse)
    label: str | None = None
    reasoning: str = ""
    lifecycle_kind: str = Field(alias="lifecycleKind")

    model_config = {"populate_by_name": True}


class ReviewOptionResponse(BaseModel):
    """needs_review=true 일 때의 미확정 후보 (mochi_items JSONB 영속 — PR-B)."""

    intent_type: Intent = Field(alias="intentType")
    label: str | None = None
    reasoning: str = ""

    model_config = {"populate_by_name": True}


class MochiItemResponse(BaseModel):
    id: UUID
    channel: IngestChannel
    url: str | None
    text: str | None
    user_memo: str | None = Field(default=None, alias="userMemo")
    intent_instances: list[IntentInstanceResponse] = Field(
        default_factory=list, alias="intentInstances"
    )
    needs_review: bool = Field(default=False, alias="needsReview")
    review_options: list[ReviewOptionResponse] = Field(
        default_factory=list, alias="reviewOptions"
    )
    summary: str | None
    importance: int
    lifecycle_kind: str = Field(alias="lifecycleKind")
    sync_kind: str = Field(alias="syncKind")
    image_refs: list[ImageRefResponse] = Field(default_factory=list, alias="imageRefs")
    captured_at: datetime = Field(alias="capturedAt")
    created_at: datetime = Field(alias="createdAt")

    model_config = {"populate_by_name": True}


class MochiItemListResponse(BaseModel):
    """날짜 구간 모찌 목록 — 모찌들(캘린더) 탭에서 특정 날짜 선택 시 그날 목록."""

    items: list[MochiItemResponse] = Field(default_factory=list)


class CalendarDayResponse(BaseModel):
    """월간 캘린더의 하루 셀 — KST 날짜·개수·대표 Intent·대표 썸네일 object_key."""

    date: str
    count: int
    representative_intent: Intent | None = Field(default=None, alias="representativeIntent")
    thumbnail_object_key: str | None = Field(default=None, alias="thumbnailObjectKey")

    model_config = {"populate_by_name": True}


class MonthlyCalendarResponse(BaseModel):
    """월간 캘린더 집계 응답 — 모찌들 탭 상단 달력."""

    year: int
    month: int
    days: list[CalendarDayResponse] = Field(default_factory=list)


class UpcomingTodoResponse(BaseModel):
    """마감 임박 미완료 todo 1건 — 모찌들 탭 하단 할 일 리스트.

    ``due_at`` 은 entities(kind='deadline') free-text 를 서버가 파싱한 값(미상이면 null),
    ``due_label`` 은 파싱 전 원문(클라 표시·디버깅용).
    """

    item: MochiItemResponse
    due_at: datetime | None = Field(default=None, alias="dueAt")
    due_label: str | None = Field(default=None, alias="dueLabel")

    model_config = {"populate_by_name": True}


class UpcomingTodoListResponse(BaseModel):
    todos: list[UpcomingTodoResponse] = Field(default_factory=list)


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
