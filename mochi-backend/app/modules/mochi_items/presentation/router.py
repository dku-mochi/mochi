from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, Query, status

from app.core.config import get_settings
from app.core.deps import CaptureImageStorageDep, DBSession
from app.core.error_envelope import DomainError, FeatureUnavailableError, NotFoundError
from app.core.security import CurrentUser
from app.modules.mochi_items.application.back_tap_ingest import (
    BackTapIngest,
    BackTapIngestCommand,
)
from app.modules.mochi_items.application.ingest import Ingest, IngestCommand
from app.modules.mochi_items.application.override_intent import (
    OverrideIntent,
    OverrideIntentCommand,
)
from app.modules.mochi_items.application.queries import (
    GetMonthlyCalendar,
    ListMochiItemsInRange,
    ListUpcomingTodos,
)
from app.modules.mochi_items.domain.entities import ImageRef, MochiItem
from app.modules.mochi_items.domain.ports import CaptureImageStorage, ObjectStat
from app.modules.mochi_items.infrastructure.outbox import OutboxNotifier
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.modules.mochi_items.presentation.schemas import (
    BackTapMochiItemRequest,
    CalendarDayResponse,
    ImageRefResponse,
    IntentCandidateResponse,
    IntentOverrideRequest,
    MochiItemCreateRequest,
    MochiItemListResponse,
    MochiItemResponse,
    MonthlyCalendarResponse,
    PresignRequest,
    PresignResponse,
    UpcomingTodoListResponse,
    UpcomingTodoResponse,
)
from app.shared.intent import Intent

router = APIRouter(prefix="/mochi_items", tags=["mochi_items"])

# 백탭 캡쳐 이미지 상한 — JPEG q60 의 ~5x buffer (lab 측정에선 평균 ~85KB).
_BACK_TAP_MAX_BYTES = 5 * 1024 * 1024
_BACK_TAP_ALLOWED_MIME = ("image/jpeg", "image/png")


def _require_owned_object_key(object_key: str, *, owner_id: UUID) -> None:
    """클라가 보낸 object_key 가 presign 이 발급하는 owner-scoped prefix 인지 강제 (IDOR 방지).

    presign(`GCSSignedUrlIssuer`)은 `{prefix}/{owner_id}/{sha}.{ext}` 만 발급한다. 이 검증이
    없으면 다른 사용자의 object_key 를 보내 cross-tenant 원본을 Gemini 로 분석시킬 수 있다.
    """
    expected_prefix = f"{get_settings().gcs_capture_prefix}/{owner_id}/"
    if not object_key.startswith(expected_prefix):
        raise DomainError(
            "object_key does not belong to the authenticated user",
            code="mochi_item.object_key_forbidden",
        )


async def _verify_uploaded_object(
    storage: CaptureImageStorage | None, object_key: str, *, owner_id: UUID
) -> ObjectStat:
    """업로드된 객체를 GCS 실제 metadata 로 검증 (P1-1 owner-prefix + P1-2 무결성).

    클라가 신고한 byteSize/mimeType 을 신뢰하지 않고 owner-scoped prefix·객체 존재·
    size 상한·content-type 화이트리스트를 서버가 직접 확인한다.
    """
    _require_owned_object_key(object_key, owner_id=owner_id)
    if storage is None:
        raise FeatureUnavailableError(
            "Capture image storage is not configured",
            code="mochi_item.storage_unconfigured",
        )
    stat = await storage.stat(object_key=object_key)
    if stat is None:
        raise DomainError(
            "Uploaded object not found in storage (presign→PUT 미완?)",
            code="mochi_item.object_not_found",
        )
    if stat.size > _BACK_TAP_MAX_BYTES:
        raise DomainError(
            f"Image too large: {stat.size} bytes > {_BACK_TAP_MAX_BYTES}",
            code="mochi_item.image_too_large",
        )
    if stat.content_type not in _BACK_TAP_ALLOWED_MIME:
        raise DomainError(
            f"Unsupported image content_type {stat.content_type!r}; expected JPEG/PNG",
            code="mochi_item.unsupported_image_type",
        )
    return stat


def _to_response(item: MochiItem) -> MochiItemResponse:
    return MochiItemResponse(
        id=item.id,
        channel=item.source.channel,
        url=item.source.url,
        text=item.source.text,
        user_memo=item.source.user_memo,
        intent=item.intent,
        secondary_intents=list(item.secondary_intents),
        intent_applicability={i.value: v for i, v in item.intent_applicability.items()},
        summary=item.summary,
        importance=item.importance,
        confidence=item.confidence,
        candidates=[
            IntentCandidateResponse(
                label=c.label,
                intent=c.intent,
                applicability=c.applicability,
                reasoning=c.reasoning,
            )
            for c in item.intent_candidates
        ],
        lifecycle_kind=item.lifecycle.kind.value,
        sync_kind=item.sync.kind,
        image_refs=[
            ImageRefResponse(
                object_key=img.object_key,
                mime_type=img.mime_type,
                byte_size=img.byte_size,
                sha256=img.sha256,
            )
            for img in item.source.image_refs
        ],
        captured_at=item.source.captured_at,
        created_at=item.created_at,
    )


@router.post("", status_code=status.HTTP_201_CREATED, response_model=MochiItemResponse)
async def create_mochi_item(
    payload: MochiItemCreateRequest,
    db: DBSession,
    user: CurrentUser,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> MochiItemResponse:
    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for MochiItem ingestion",
            code="mochi_item.missing_idempotency_key",
        )
    for img in payload.image_refs:
        if img.object_key is not None:
            _require_owned_object_key(img.object_key, owner_id=user)

    use_case = Ingest(
        repository=PostgresMochiItemRepository(db),
        notifier=OutboxNotifier(db),
    )
    result = await use_case.execute(
        IngestCommand(
            owner_id=user,
            channel=payload.channel,
            url=payload.url,
            text=payload.text,
            user_memo=payload.user_memo,
            image_refs=tuple(
                ImageRef(
                    sha256=img.sha256,
                    mime_type=img.mime_type,
                    byte_size=img.byte_size,
                    object_key=img.object_key,
                )
                for img in payload.image_refs
            ),
            idempotency_key=idempotency_key,
        )
    )
    await db.commit()
    return _to_response(result.item)


@router.post(
    "/back-tap",
    status_code=status.HTTP_201_CREATED,
    response_model=MochiItemResponse,
)
async def create_back_tap_mochi_item(
    payload: BackTapMochiItemRequest,
    db: DBSession,
    user: CurrentUser,
    storage: CaptureImageStorageDep,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> MochiItemResponse:
    """백탭 캡쳐 — Signed URL 로 GCS 에 올린 ``objectKey`` 를 받아 MochiItem(`.screenshot`) 적재.

    4-Intent 후보·confidence 는 outbox worker(``AgentOrchestrator``)가 비동기로 채우고,
    iOS 는 폴링(`GET /mochi_items/{id}`)으로 결과를 반영한다. 동기 분류는 제거됐다 —
    Gemini 이중 호출 방지 + DB↔Realm 일관성.
    """

    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for MochiItem ingestion",
            code="mochi_item.missing_idempotency_key",
        )
    # 클라 신고값(byteSize/mimeType)을 믿지 않고 GCS 실제 객체로 검증 (owner-prefix 포함).
    stat = await _verify_uploaded_object(storage, payload.object_key, owner_id=user)

    use_case = BackTapIngest(
        repository=PostgresMochiItemRepository(db),
        notifier=OutboxNotifier(db),
    )
    result = await use_case.execute(
        BackTapIngestCommand(
            owner_id=user,
            idempotency_key=idempotency_key,
            object_key=payload.object_key,
            mime_type=stat.content_type or payload.mime_type,
            byte_size=stat.size,
            sha256=payload.sha256,
            user_memo=payload.user_memo,
        )
    )
    await db.commit()
    return _to_response(result.item)


@router.post("/presign", response_model=PresignResponse)
async def presign_capture_upload(
    payload: PresignRequest,
    user: CurrentUser,
    storage: CaptureImageStorageDep,
) -> PresignResponse:
    """캡처 이미지 업로드용 V4 Signed PUT URL 발급.

    클라이언트는 이 URL 로 GCS 에 직접 PUT 한 뒤, 받은 ``objectKey`` 를
    ``POST /mochi_items/back-tap`` (또는 ``POST /mochi_items``) 로 전달한다.
    서버는 이미지 bytes 를 만지지 않는다.
    """
    if payload.mime_type not in _BACK_TAP_ALLOWED_MIME:
        raise DomainError(
            f"Unsupported image content_type {payload.mime_type!r}; expected JPEG/PNG",
            code="mochi_item.unsupported_image_type",
        )
    if storage is None:
        raise FeatureUnavailableError(
            "Capture image storage is not configured",
            code="mochi_item.storage_unconfigured",
        )
    signed = await storage.issue_upload_url(
        owner_id=user, sha256=payload.sha256, mime_type=payload.mime_type
    )
    return PresignResponse(
        object_key=signed.object_key,
        upload_url=signed.upload_url,
        expires_at=signed.expires_at,
    )


@router.patch("/{mochi_item_id}/intent", response_model=MochiItemResponse)
async def override_mochi_item_intent(
    mochi_item_id: UUID,
    payload: IntentOverrideRequest,
    db: DBSession,
    user: CurrentUser,
) -> MochiItemResponse:
    use_case = OverrideIntent(repository=PostgresMochiItemRepository(db))
    item = await use_case.execute(
        OverrideIntentCommand(
            owner_id=user,
            mochi_item_id=mochi_item_id,
            new_primary=payload.intent,
        )
    )
    await db.commit()
    return _to_response(item)


# ── 모찌들(캘린더) 탭 조회 라우트 ──
# 정적 세그먼트(/calendar, /todos/upcoming) 와 list("") 는 동적 "/{mochi_item_id}" 보다
# 먼저 선언해야 'calendar' 등을 UUID 로 파싱해 422 나는 라우트 충돌을 피한다.


@router.get("", response_model=MochiItemListResponse)
async def list_mochi_items(
    db: DBSession,
    user: CurrentUser,
    captured_from: Annotated[datetime | None, Query(alias="capturedFrom")] = None,
    captured_to: Annotated[datetime | None, Query(alias="capturedTo")] = None,
    intent: Intent | None = None,
    limit: int = 100,
) -> MochiItemListResponse:
    """모찌들 탭 — captured_at 구간 내 owner 모찌 목록(특정 날짜 선택 시 그날 sheet).

    ``capturedFrom``/``capturedTo`` 는 ISO8601(UTC 권장). ``intent`` 로 4-Intent 필터.
    """
    use_case = ListMochiItemsInRange(repository=PostgresMochiItemRepository(db))
    items = await use_case.execute(
        owner_id=user,
        captured_from=captured_from,
        captured_to=captured_to,
        intent=intent,
        limit=max(1, min(limit, 200)),
    )
    return MochiItemListResponse(items=[_to_response(item) for item in items])


@router.get("/calendar", response_model=MonthlyCalendarResponse)
async def get_monthly_calendar(
    db: DBSession,
    user: CurrentUser,
    year: int,
    month: int,
) -> MonthlyCalendarResponse:
    """모찌들 탭 — KST 월간 캘린더(날짜별 개수·대표 Intent·대표 썸네일 object_key)."""
    if not 1 <= month <= 12:
        raise DomainError("month must be between 1 and 12", code="mochi_item.invalid_month")
    if not 2000 <= year <= 2200:
        raise DomainError("year is out of supported range", code="mochi_item.invalid_year")
    use_case = GetMonthlyCalendar(repository=PostgresMochiItemRepository(db))
    days = await use_case.execute(owner_id=user, year=year, month=month)
    return MonthlyCalendarResponse(
        year=year,
        month=month,
        days=[
            CalendarDayResponse(
                date=day.date,
                count=day.count,
                representative_intent=day.representative_intent,
                thumbnail_object_key=day.thumbnail_object_key,
            )
            for day in days
        ],
    )


@router.get("/todos/upcoming", response_model=UpcomingTodoListResponse)
async def get_upcoming_todos(
    db: DBSession,
    user: CurrentUser,
    limit: int = 20,
) -> UpcomingTodoListResponse:
    """모찌들 탭 하단 — 마감 임박·미완료(lifecycle active) todo 리스트.

    마감일은 ``entities(kind='deadline')`` free-text 를 서버가 파싱해 임박순 정렬하며,
    파싱 불가/마감 미상 todo 는 목록 뒤로 둔다(``dueAt`` null).
    """
    use_case = ListUpcomingTodos(repository=PostgresMochiItemRepository(db))
    todos = await use_case.execute(owner_id=user, limit=max(1, min(limit, 100)))
    return UpcomingTodoListResponse(
        todos=[
            UpcomingTodoResponse(
                item=_to_response(todo.item),
                due_at=todo.due_at,
                due_label=todo.due_label,
            )
            for todo in todos
        ]
    )


@router.get("/{mochi_item_id}", response_model=MochiItemResponse)
async def get_mochi_item(mochi_item_id: UUID, db: DBSession, user: CurrentUser) -> MochiItemResponse:
    repo = PostgresMochiItemRepository(db)
    item = await repo.find_by_id(owner_id=user, mochi_item_id=mochi_item_id)
    if not item:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
    return _to_response(item)
