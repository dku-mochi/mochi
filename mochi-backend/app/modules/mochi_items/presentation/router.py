from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, Query, status
from sqlalchemy import text

from app.core.config import get_settings
from app.core.deps import CaptureImageStorageDep, DBSession
from app.core.error_envelope import DomainError, FeatureUnavailableError, NotFoundError
from app.core.security import CurrentUser
from app.modules.mochi_items.application.delete_mochi_item import (
    DeleteMochiItem,
    DeleteMochiItemCommand,
)
from app.modules.mochi_items.application.ingest import Ingest, IngestCommand
from app.modules.mochi_items.application.queries import (
    GetMonthlyCalendar,
    ListMochiItemsInRange,
    ListUpcomingTodos,
)
from app.modules.mochi_items.application.update_instance_lifecycle import (
    UpdateInstanceLifecycle,
    UpdateInstanceLifecycleCommand,
)
from app.modules.mochi_items.domain.entities import ImageRef, MochiItem
from app.modules.mochi_items.domain.ports import CaptureImageStorage, ObjectStat
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleState
from app.modules.mochi_items.infrastructure.outbox import OutboxNotifier
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.modules.mochi_items.presentation.schemas import (
    CalendarDayResponse,
    ImageRefResponse,
    InstanceLifecycleUpdateRequest,
    IntentInstanceResponse,
    IntentPayloadResponse,
    MochiItemCreateRequest,
    MochiItemListResponse,
    MochiItemResponse,
    MonthlyCalendarResponse,
    PresignRequest,
    PresignResponse,
    ReanalyzeRequest,
    ReviewOptionResponse,
    UpcomingTodoListResponse,
    UpcomingTodoResponse,
)
from app.shared.intent import Intent

router = APIRouter(prefix="/mochi_items", tags=["mochi_items"])

# 캡처 이미지 상한 — 모든 채널 공통(공유시트 원본 포함). ImageRefDTO.byte_size le 와 일치.
_CAPTURE_MAX_BYTES = 50 * 1024 * 1024
_CAPTURE_ALLOWED_MIME = ("image/jpeg", "image/png")


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
    """업로드된 객체를 GCS 실제 metadata 로 검증 (owner-prefix + 무결성).

    클라가 신고한 byteSize/mimeType 을 신뢰하지 않고 owner-scoped prefix·객체 존재·
    size 상한·content-type 화이트리스트를 서버가 직접 확인한다. (2026-06-04 ingest 단일화로
    백탭 전용 경로에서 일반 ingest 로 흡수 — object_key 를 가진 모든 imageRef 에 적용.)
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
    if stat.size > _CAPTURE_MAX_BYTES:
        raise DomainError(
            f"Image too large: {stat.size} bytes > {_CAPTURE_MAX_BYTES}",
            code="mochi_item.image_too_large",
        )
    if stat.content_type not in _CAPTURE_ALLOWED_MIME:
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
        intent_instances=[
            IntentInstanceResponse(
                id=inst.id,
                intent_type=inst.intent_type,
                payload=IntentPayloadResponse(
                    title=inst.payload.title,
                    date=inst.payload.date,
                    time=inst.payload.time,
                    deadline=inst.payload.deadline,
                    person=inst.payload.person,
                    topic=inst.payload.topic,
                    url=inst.payload.url,
                    note=inst.payload.note,
                ),
                label=inst.label,
                reasoning=inst.reasoning,
                lifecycle_kind=inst.lifecycle.kind.value,
                lifecycle_archive_reason=(
                    inst.lifecycle.archive_reason.value if inst.lifecycle.archive_reason else None
                ),
            )
            for inst in item.intent_instances
        ],
        needs_review=item.needs_review,
        review_options=[
            ReviewOptionResponse(
                intent_type=opt.intent_type,
                label=opt.label,
                reasoning=opt.reasoning,
            )
            for opt in item.review_options
        ],
        summary=item.summary,
        importance=item.importance,
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
    storage: CaptureImageStorageDep,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> MochiItemResponse:
    """단일 ingest 진입점 — 모든 입력 채널(링크·텍스트·스크린샷/백탭).

    object_key 를 가진 imageRef 는 채널 무관하게 GCS 실측 검증을 거친다(owner-prefix + size +
    content-type). 4-Intent instance·needs_review 는 outbox worker(``AgentOrchestrator``)가
    비동기로 채우고, iOS 는 폴링(`GET /mochi_items/{id}`)으로 반영한다.
    """
    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for MochiItem ingestion",
            code="mochi_item.missing_idempotency_key",
        )
    image_refs: list[ImageRef] = []
    for img in payload.image_refs:
        if img.object_key is not None:
            # 클라 신고값 대신 GCS 실측값 사용 (위조 size/content-type 차단).
            stat = await _verify_uploaded_object(storage, img.object_key, owner_id=user)
            image_refs.append(
                ImageRef(
                    sha256=img.sha256,
                    mime_type=stat.content_type or img.mime_type,
                    byte_size=stat.size,
                    object_key=img.object_key,
                )
            )
        else:
            image_refs.append(
                ImageRef(
                    sha256=img.sha256,
                    mime_type=img.mime_type,
                    byte_size=img.byte_size,
                    object_key=None,
                )
            )

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
            image_refs=tuple(image_refs),
            idempotency_key=idempotency_key,
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

    클라이언트는 이 URL 로 GCS 에 직접 PUT 한 뒤, 받은 ``objectKey`` 를 ``POST /mochi_items``
    의 imageRef 로 전달한다. 서버는 이미지 bytes 를 만지지 않는다.
    """
    if payload.mime_type not in _CAPTURE_ALLOWED_MIME:
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


# ── 캘린더 탭 조회 라우트 ──
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
    """캘린더 탭 — captured_at 구간 내 owner 모찌 목록(특정 날짜 선택 시 그날 sheet).

    ``capturedFrom``/``capturedTo`` 는 ISO8601(UTC 권장). ``intent`` 로 4-Intent 필터
    (해당 type 의 instance 가 있는 item).
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
    """캘린더 탭 — KST 월간 캘린더(날짜별 개수·대표 Intent·대표 썸네일 object_key)."""
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
    """캘린더 탭 하단 — 마감 임박·미완료(todo instance active) todo 리스트.

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


@router.post("/{mochi_item_id}/reanalyze", status_code=status.HTTP_202_ACCEPTED)
async def reanalyze_mochi_item(
    mochi_item_id: UUID,
    payload: ReanalyzeRequest,
    db: DBSession,
    user: CurrentUser,
) -> None:
    """needs_review 항목 재분석 — "다른 의도"에서 사용자가 적은 의도 힌트로 다시 분석한다.

    기존 outbox→``AgentOrchestrator`` 파이프라인을 그대로 재실행하되, 힌트를 분석 프롬프트에만
    합류시킨다(outbox 행에 일시 적재, ``mochi_items`` 미저장 — 사용자 메모 오염 방지).
    같은 item 을 재분석하므로 중복 캡처가 생기지 않는다.
    """
    repo = PostgresMochiItemRepository(db)
    item = await repo.find_by_id(owner_id=user, mochi_item_id=mochi_item_id)
    if not item:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
    # 폴링이 직전 분석의 stale `analyzed` 를 재적용하지 않도록 처리상태를 분석 대기로 되돌린다 —
    # worker 가 재분석을 끝내면 다시 `analyzed` 로 전이한다(UPDATE 패턴은 worker 와 동일).
    await db.execute(
        text("UPDATE mochi_items SET lifecycle_kind='ingested' WHERE id=:id AND owner_id=:owner"),
        {"id": str(mochi_item_id), "owner": str(user)},
    )
    await OutboxNotifier(db).emit(
        owner_id=user, mochi_item_id=mochi_item_id, reanalysis_hint=payload.user_hint
    )
    await db.commit()


@router.post(
    "/{mochi_item_id}/instances/{instance_id}/lifecycle",
    response_model=MochiItemResponse,
)
async def update_instance_lifecycle(
    mochi_item_id: UUID,
    instance_id: UUID,
    payload: InstanceLifecycleUpdateRequest,
    db: DBSession,
    user: CurrentUser,
) -> MochiItemResponse:
    """intent instance 의 의미 lifecycle 전이 — 캘린더 todo 완료/완료취소.

    완료: ``lifecycleKind=archived`` + ``archiveReason=todoCompleted``.
    완료취소: ``lifecycleKind=active``(reason 생략). 합법성은 instance 의 intent_type 으로
    검증한다 — 불법 전이는 409(`intent_instance.illegal_transition`), 없는 instance 는 404.
    todo 는 양방향(완료↔미완료)이 합법이라 잘못 누른 완료를 되돌릴 수 있다.
    """
    use_case = UpdateInstanceLifecycle(repository=PostgresMochiItemRepository(db))
    item = await use_case.execute(
        UpdateInstanceLifecycleCommand(
            owner_id=user,
            mochi_item_id=mochi_item_id,
            instance_id=instance_id,
            target=InstanceLifecycleState(
                kind=payload.lifecycle_kind,
                archive_reason=payload.archive_reason,
            ),
        )
    )
    await db.commit()
    return _to_response(item)


@router.delete("/{mochi_item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_mochi_item(
    mochi_item_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> None:
    """기록 soft delete — 행을 지우지 않고 ``deleted_at`` 마킹(되돌릴 수 있게, users 동일 패턴).

    owner-scoped. 없는/이미 삭제된/다른 owner 항목은 404(`mochi_item.not_found`). 이후 모든 조회
    (find/list/calendar/todos)가 ``deleted_at IS NULL`` 로 가려 목록·캘린더에서 사라진다.
    """
    use_case = DeleteMochiItem(repository=PostgresMochiItemRepository(db))
    await use_case.execute(
        DeleteMochiItemCommand(owner_id=user, mochi_item_id=mochi_item_id)
    )
    await db.commit()
