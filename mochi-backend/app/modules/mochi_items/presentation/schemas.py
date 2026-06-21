from uuid import UUID

from pydantic import BaseModel, Field

from app.core.schema import UtcDateTime
from app.modules.mochi_items.domain.entities import IngestChannel
from app.modules.mochi_items.domain.value_objects import ArchiveReason, InstanceLifecycleKind
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


class IntentPayloadPatchDTO(BaseModel):
    """instance payload 의 부분 필드 — PATCH(병합)·confirmedInstances(생성) 공용."""

    title: str | None = None
    date: str | None = None
    time: str | None = None
    end_date: str | None = Field(default=None, alias="endDate")
    end_time: str | None = Field(default=None, alias="endTime")
    deadline: str | None = None
    person: str | None = None
    topic: str | None = None
    url: str | None = None
    note: str | None = None

    model_config = {"populate_by_name": True}

    def non_null_fields(self) -> dict[str, str]:
        return {k: v for k, v in self.model_dump().items() if v is not None}


class ConfirmedInstanceDTO(BaseModel):
    """채팅 proposal 확정으로 생성되는 **사용자 확정 instance** — 분석 생략 (§5.2 예외).

    사용자가 카드에서 확정한 구조라 LLM 재분석이 덮으면 안 된다 — instance 가 곧바로
    active 로 태어나고 outbox(분석 파이프라인)에 들어가지 않는다.
    """

    intent_type: Intent = Field(alias="intentType")
    payload: IntentPayloadPatchDTO = Field(default_factory=IntentPayloadPatchDTO)
    label: str | None = None

    model_config = {"populate_by_name": True}


class MochiItemCreateRequest(BaseModel):
    """클라이언트(iOS)가 보내는 MochiItem ingestion payload.

    iOS는 본 스키마와 동일한 모양의 ``MochiItemIngestRequest`` 를 송신한다 — 양쪽이 OpenAPI 로 검증된다.
    ``confirmedInstances`` 가 있으면 분석 파이프라인을 생략하고 확정 instance 를 직접 생성한다
    (채팅 schedule proposal 확정 — DOMAIN_DESIGN §5.2 예외).
    """

    channel: IngestChannel
    url: str | None = None
    text: str | None = None
    user_memo: str | None = Field(default=None, alias="userMemo")
    image_refs: list[ImageRefDTO] = Field(default_factory=list, alias="imageRefs")
    confirmed_instances: list[ConfirmedInstanceDTO] = Field(default_factory=list, alias="confirmedInstances")

    model_config = {"populate_by_name": True}


class InstanceChangeRequest(BaseModel):
    """PATCH 의 instance 단위 변경 — payload 는 제공 필드만 병합, lifecycle 은 정책 검증."""

    instance_id: UUID = Field(alias="instanceId")
    payload: IntentPayloadPatchDTO | None = None
    label: str | None = None
    lifecycle_kind: InstanceLifecycleKind | None = Field(default=None, alias="lifecycleKind")
    archive_reason: ArchiveReason | None = Field(default=None, alias="archiveReason")

    model_config = {"populate_by_name": True}


class MochiItemUpdateRequest(BaseModel):
    """PATCH /mochi_items/{id} — 채팅 수정 proposal 확정 실행 (콘텐츠 + instance, 한 트랜잭션).

    None/누락 = 변경 없음 (null 로 필드 클리어는 미지원 — 채팅 수정 시나리오에 불필요).
    """

    text: str | None = None
    user_memo: str | None = Field(default=None, alias="userMemo")
    summary: str | None = None
    instances: list[InstanceChangeRequest] = Field(default_factory=list)

    model_config = {"populate_by_name": True}


class ReanalyzeRequest(BaseModel):
    """needs_review 항목 재분석 요청 — 사용자가 "다른 의도"를 고르며 자연어로 적은 의도 힌트.

    힌트는 분석 프롬프트 context 에만 합류하고 **outbox 행에만 일시 적재**된다.
    `mochi_items`·`user_memo` 에는 저장하지 않는다(사용자가 직접 쓴 메모로 오해하는 것을 막는다).
    """

    user_hint: str = Field(min_length=1, max_length=500, alias="userHint")

    model_config = {"populate_by_name": True}


class InstanceLifecycleUpdateRequest(BaseModel):
    """intent instance 의 의미 lifecycle 전이 요청 — 캘린더 todo 완료/완료취소.

    완료: ``lifecycleKind=archived`` + ``archiveReason=todoCompleted``.
    완료취소: ``lifecycleKind=active`` (reason 생략). 전이 합법성은 instance 의 intent_type 으로
    ``lifecycle_policy`` 가 검증한다(불법이면 409).
    """

    lifecycle_kind: InstanceLifecycleKind = Field(alias="lifecycleKind")
    archive_reason: ArchiveReason | None = Field(default=None, alias="archiveReason")

    model_config = {"populate_by_name": True}


class FavoriteUpdateRequest(BaseModel):
    """즐겨찾기 신호 set-state 요청. ``isFavorite=true`` 즐겨찾기 추가, ``false`` 해제.
    같은 값 재전송은 멱등 no-op(완료 토글과 동일 규약)."""

    is_favorite: bool = Field(alias="isFavorite")

    model_config = {"populate_by_name": True}


class IntentPayloadResponse(BaseModel):
    """instance 의 구조화 속성 (전부 optional). date/time 은 시작, endDate/endTime 은 기간형 일정의 끝."""

    title: str | None = None
    date: str | None = None
    time: str | None = None
    end_date: str | None = Field(default=None, alias="endDate")
    end_time: str | None = Field(default=None, alias="endTime")
    deadline: str | None = None
    person: str | None = None
    topic: str | None = None
    url: str | None = None
    note: str | None = None

    model_config = {"populate_by_name": True}


class IntentInstanceResponse(BaseModel):
    """저장된 의도 instance 1건 — 곧 active. 점수/위계 없음.

    ``id`` 는 서버 instance 식별자 — iOS 가 보존해 완료/완료취소(lifecycle 전이) API 의 대상으로 쓴다.
    (재분석 시 delete-reinsert 로 id 가 갈리는 한계는 known-drift — CHANGELOG 참고.)
    """

    id: UUID = Field(alias="instanceId")
    intent_type: Intent = Field(alias="intentType")
    payload: IntentPayloadResponse = Field(default_factory=IntentPayloadResponse)
    label: str | None = None
    reasoning: str = ""
    lifecycle_kind: str = Field(alias="lifecycleKind")
    lifecycle_archive_reason: str | None = Field(default=None, alias="lifecycleArchiveReason")

    model_config = {"populate_by_name": True}


class ReviewOptionResponse(BaseModel):
    """needs_review=true 일 때의 미확정 후보 (mochi_items JSONB 영속 — PR-B)."""

    intent_type: Intent = Field(alias="intentType")
    label: str | None = None
    reasoning: str = ""

    model_config = {"populate_by_name": True}


class ReferenceLinkResponse(BaseModel):
    """상세 화면 "지금 할 수 있어요" 에 붙일 참고 URL."""

    url: str
    title: str
    label: str
    role: str
    provider: str
    rank_profile: str = Field(alias="rankProfile")
    source: str | None = None
    usefulness: int | None = None
    subtitle: str | None = None
    price_text: str | None = Field(default=None, alias="priceText")

    model_config = {"populate_by_name": True}


class MochiItemResponse(BaseModel):
    id: UUID
    channel: IngestChannel
    url: str | None
    text: str | None
    user_memo: str | None = Field(default=None, alias="userMemo")
    intent_instances: list[IntentInstanceResponse] = Field(default_factory=list, alias="intentInstances")
    needs_review: bool = Field(default=False, alias="needsReview")
    review_options: list[ReviewOptionResponse] = Field(default_factory=list, alias="reviewOptions")
    summary: str | None
    category: str | None = None
    shopping_product_query: str | None = Field(default=None, alias="shoppingProductQuery")
    reference_links: list[ReferenceLinkResponse] = Field(default_factory=list, alias="referenceLinks")
    importance: int
    is_favorite: bool = Field(default=False, alias="isFavorite")
    lifecycle_kind: str = Field(alias="lifecycleKind")
    sync_kind: str = Field(alias="syncKind")
    image_refs: list[ImageRefResponse] = Field(default_factory=list, alias="imageRefs")
    captured_at: UtcDateTime = Field(alias="capturedAt")
    created_at: UtcDateTime = Field(alias="createdAt")

    model_config = {"populate_by_name": True}


class MochiItemListResponse(BaseModel):
    """날짜 구간 모찌 목록 — 캘린더 탭에서 특정 날짜 선택 시 그날 목록."""

    items: list[MochiItemResponse] = Field(default_factory=list)


class CalendarDayResponse(BaseModel):
    """월간 캘린더의 하루 셀 — KST 날짜·개수·대표 Intent·대표 썸네일 object_key."""

    date: str
    count: int
    representative_intent: Intent | None = Field(default=None, alias="representativeIntent")
    thumbnail_object_key: str | None = Field(default=None, alias="thumbnailObjectKey")

    model_config = {"populate_by_name": True}


class MonthlyCalendarResponse(BaseModel):
    """월간 캘린더 집계 응답 — 캘린더 탭 상단 달력."""

    year: int
    month: int
    days: list[CalendarDayResponse] = Field(default_factory=list)


class UpcomingTodoResponse(BaseModel):
    """마감 임박 미완료 todo 1건 — 캘린더 탭 하단 할 일 리스트.

    ``due_at`` 은 entities(kind='deadline') free-text 를 서버가 파싱한 값(미상이면 null),
    ``due_label`` 은 파싱 전 원문(클라 표시·디버깅용).
    """

    item: MochiItemResponse
    due_at: UtcDateTime | None = Field(default=None, alias="dueAt")
    due_label: str | None = Field(default=None, alias="dueLabel")

    model_config = {"populate_by_name": True}


class UpcomingTodoListResponse(BaseModel):
    todos: list[UpcomingTodoResponse] = Field(default_factory=list)


class UpcomingActionableResponse(BaseModel):
    """ "이번주 정리"의 "아직 안 끝났어요" 1건 — 미해결 todo 또는 다가올 schedule.

    ``is_schedule`` false(=todo)면 클라가 카드에서 1-tap 완료(``instance_id`` 가 lifecycle 전이 대상).
    ``due_at`` 은 instance/entities free-text 를 서버가 파싱한 값(미상이면 null), ``due_label`` 은 원문.
    """

    item: MochiItemResponse
    due_at: UtcDateTime | None = Field(default=None, alias="dueAt")
    due_label: str | None = Field(default=None, alias="dueLabel")
    is_schedule: bool = Field(alias="isSchedule")
    instance_id: UUID = Field(alias="instanceId")

    model_config = {"populate_by_name": True}


class UpcomingActionableListResponse(BaseModel):
    actionables: list[UpcomingActionableResponse] = Field(default_factory=list)


class MonthlyDigestGroupResponse(BaseModel):
    """정규화된 coarse 카테고리 1묶음 — 그 그룹에 속한 item id 목록(captured_at desc)."""

    coarse: str
    item_ids: list[UUID] = Field(default_factory=list, alias="itemIds")

    model_config = {"populate_by_name": True}


class MonthlyDigestResponse(BaseModel):
    """이번 달 정리 — 모찌 한마디 + 정규화된 카테고리 그룹.

    ``generated`` 가 false 면 그 달 항목이 적어 LLM 을 돌리지 않은 정적 폴백이다(클라가 캐시 정책에 활용).
    카테고리 정규화는 서버가 item.category 를 write 한 결과이므로, 클라는 응답의 itemIds 로 로컬 캐시를
    함께 갱신한다.
    """

    greeting: str
    groups: list[MonthlyDigestGroupResponse] = Field(default_factory=list)
    generated: bool = True


class PresignRequest(BaseModel):
    """캡처 이미지 업로드용 Signed PUT URL 발급 요청."""

    sha256: str = Field(min_length=64, max_length=64)
    mime_type: str = Field(alias="mimeType")

    model_config = {"populate_by_name": True}


class PresignResponse(BaseModel):
    """발급된 V4 Signed PUT URL + 서버가 부여한 object_key."""

    object_key: str = Field(alias="objectKey")
    upload_url: str = Field(alias="uploadURL")
    expires_at: UtcDateTime = Field(alias="expiresAt")

    model_config = {"populate_by_name": True}


class DownloadUrlRequest(BaseModel):
    """업로드된 캡처 이미지를 직접 GET 할 Signed URL 발급 요청 — 앱 재설치 후 이미지 복구."""

    object_key: str = Field(alias="objectKey")

    model_config = {"populate_by_name": True}


class DownloadUrlResponse(BaseModel):
    """발급된 V4 Signed GET URL."""

    download_url: str = Field(alias="downloadURL")
    expires_at: UtcDateTime = Field(alias="expiresAt")

    model_config = {"populate_by_name": True}
