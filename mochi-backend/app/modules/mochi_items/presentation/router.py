from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, Query, status
from sqlalchemy import text

from app.core.config import get_settings
from app.core.deps import CaptureImageStorageDep, DBSession
from app.core.error_envelope import DomainError, FeatureUnavailableError, NotFoundError
from app.core.security import CurrentCaptureUser, CurrentUser
from app.modules.mochi_items.application.delete_mochi_item import (
    DeleteMochiItem,
    DeleteMochiItemCommand,
)
from app.modules.mochi_items.application.ingest import Ingest, IngestCommand
from app.modules.mochi_items.application.queries import (
    GetMonthlyCalendar,
    ListMochiItemsInRange,
    ListUpcomingActionables,
    ListUpcomingTodos,
)
from app.modules.mochi_items.application.set_favorite import (
    SetFavorite,
    SetFavoriteCommand,
)
from app.modules.mochi_items.application.update_instance_lifecycle import (
    UpdateInstanceLifecycle,
    UpdateInstanceLifecycleCommand,
)
from app.modules.mochi_items.application.update_mochi_item import (
    InstanceChange,
    UpdateMochiItem,
    UpdateMochiItemCommand,
)
from app.modules.mochi_items.application.weekly_digest import GenerateWeeklyDigest
from app.modules.mochi_items.domain.entities import ImageRef, MochiItem
from app.modules.mochi_items.domain.ports import CaptureImageStorage, ObjectStat
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
    IntentPayload,
)
from app.modules.mochi_items.infrastructure.gemini_weekly_digest import GeminiWeeklyDigest
from app.modules.mochi_items.infrastructure.outbox import OutboxNotifier
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.modules.mochi_items.presentation.schemas import (
    CalendarDayResponse,
    DownloadUrlRequest,
    DownloadUrlResponse,
    FavoriteUpdateRequest,
    ImageRefResponse,
    InstanceLifecycleUpdateRequest,
    IntentInstanceResponse,
    IntentPayloadResponse,
    MochiItemCreateRequest,
    MochiItemListResponse,
    MochiItemResponse,
    MochiItemUpdateRequest,
    MonthlyCalendarResponse,
    PresignRequest,
    PresignResponse,
    ReanalyzeRequest,
    ReferenceLinkResponse,
    ReviewOptionResponse,
    UpcomingActionableListResponse,
    UpcomingActionableResponse,
    UpcomingTodoListResponse,
    UpcomingTodoResponse,
    WeeklyDigestGroupResponse,
    WeeklyDigestResponse,
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
                    end_date=inst.payload.end_date,
                    end_time=inst.payload.end_time,
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
        category=item.category,
        shopping_product_query=item.shopping_product_query,
        reference_links=[
            ReferenceLinkResponse(
                url=link.url,
                title=link.title,
                label=link.label,
                role=link.role,
                provider=link.provider,
                rank_profile=link.rank_profile,
                source=link.source,
                usefulness=link.usefulness,
            )
            for link in item.reference_links
        ],
        importance=item.importance,
        is_favorite=item.is_favorite,
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
    user: CurrentCaptureUser,
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
            # 채팅 proposal 확정 — 사용자 확정 instance 는 분석 생략·직접 생성 (§5.2 예외).
            confirmed_instances=tuple(
                IntentInstance(
                    intent_type=ci.intent_type,
                    payload=IntentPayload(**ci.payload.non_null_fields()),
                    label=ci.label,
                    reasoning="user-confirmed via chat proposal",
                )
                for ci in payload.confirmed_instances
            ),
        )
    )
    await db.commit()
    return _to_response(result.item)


@router.post("/presign", response_model=PresignResponse)
async def presign_capture_upload(
    payload: PresignRequest,
    user: CurrentCaptureUser,
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
    signed = await storage.issue_upload_url(owner_id=user, sha256=payload.sha256, mime_type=payload.mime_type)
    return PresignResponse(
        object_key=signed.object_key,
        upload_url=signed.upload_url,
        expires_at=signed.expires_at,
    )


@router.post("/images/download-url", response_model=DownloadUrlResponse)
async def presign_capture_download(
    payload: DownloadUrlRequest,
    user: CurrentUser,
    storage: CaptureImageStorageDep,
) -> DownloadUrlResponse:
    """업로드된 캡처 이미지를 직접 GET 할 V4 Signed URL 발급 — 앱 재설치 후 이미지 복구.

    재설치하면 로컬 Realm·이미지 파일이 사라지므로, 같은 Apple 계정으로 재로그인한 클라가
    ``GET /mochi_items`` 로 받은 imageRef 의 ``objectKey`` 로 본 엔드포인트를 호출해 원본을
    내려받아 로컬에 복원한다. owner-prefix 검증(IDOR 방지)은 업로드 검증과 동일 규약.
    """
    _require_owned_object_key(payload.object_key, owner_id=user)
    if storage is None:
        raise FeatureUnavailableError(
            "Capture image storage is not configured",
            code="mochi_item.storage_unconfigured",
        )
    signed = await storage.issue_download_url(object_key=payload.object_key)
    return DownloadUrlResponse(
        download_url=signed.download_url,
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


@router.get("/upcoming", response_model=UpcomingActionableListResponse)
async def get_upcoming_actionables(
    db: DBSession,
    user: CurrentUser,
    limit: int = 20,
) -> UpcomingActionableListResponse:
    """이번주 정리 "아직 안 끝났어요" — 미해결 todo + 다가올 schedule(임박순).

    캘린더 탭의 ``/todos/upcoming``(todo 전용)과 별개. 일시는 instance payload(deadline/date)→
    entities(kind='deadline') 순으로 파싱하며, 파싱 불가/미상은 목록 뒤로 둔다(``dueAt`` null).
    """
    use_case = ListUpcomingActionables(repository=PostgresMochiItemRepository(db))
    actionables = await use_case.execute(owner_id=user, limit=max(1, min(limit, 100)))
    return UpcomingActionableListResponse(
        actionables=[
            UpcomingActionableResponse(
                item=_to_response(actionable.item),
                due_at=actionable.due_at,
                due_label=actionable.due_label,
                is_schedule=actionable.is_schedule,
                instance_id=actionable.instance_id,
            )
            for actionable in actionables
        ]
    )


@router.post("/weekly_digest", response_model=WeeklyDigestResponse)
async def generate_weekly_digest(
    db: DBSession,
    user: CurrentUser,
    week_start: Annotated[datetime, Query(alias="weekStart")],
) -> WeeklyDigestResponse:
    """이번주 정리 — 그 주(KST 월~일) item 의 카테고리 정규화(write) + 모찌 한마디(LLM 1회).

    같은 의미인데 항목마다 제각각 생긴 category 를 LLM 이 통합 라벨로 정규화해 ``item.category`` 를
    갱신한다(파편화 수렴). 그 주 항목이 3개 미만이면 LLM 을 돌리지 않고 정적 인사로 폴백한다
    (``generated=false``). ``weekStart`` 가 어긋나도 서버가 KST 월요일 00:00 으로 재정규화한다.
    """
    use_case = GenerateWeeklyDigest(
        repository=PostgresMochiItemRepository(db),
        llm=GeminiWeeklyDigest(),
    )
    result = await use_case.execute(owner_id=user, week_start=week_start)
    await db.commit()
    return WeeklyDigestResponse(
        greeting=result.greeting,
        groups=[
            WeeklyDigestGroupResponse(coarse=group.coarse, item_ids=list(group.item_ids))
            for group in result.groups
        ],
        generated=result.generated,
    )


@router.get("/{mochi_item_id}", response_model=MochiItemResponse)
async def get_mochi_item(mochi_item_id: UUID, db: DBSession, user: CurrentUser) -> MochiItemResponse:
    repo = PostgresMochiItemRepository(db)
    item = await repo.find_by_id(owner_id=user, mochi_item_id=mochi_item_id)
    if not item:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
    return _to_response(item)


@router.patch("/{mochi_item_id}", response_model=MochiItemResponse)
async def update_mochi_item(
    mochi_item_id: UUID,
    payload: MochiItemUpdateRequest,
    db: DBSession,
    user: CurrentUser,
) -> MochiItemResponse:
    """채팅 수정 proposal 확정 실행 — 콘텐츠 + instance 변경을 한 트랜잭션으로 (journal 2026-06-10 M1).

    - 콘텐츠(text/userMemo/summary): 제공 필드만 갱신 (null 클리어 미지원).
    - instances[]: payload 병합("일정 3시로" = time 만 교체) · label · lifecycle 전이
      (``lifecycle_policy`` 검증, 불법 409).
    - instance 미실재 404(`intent_instance.not_found`) — proposal 카드 생성~확정 사이
      reanalyze 가 instance 를 재작성한 경우의 만료 신호 (iOS 가 카드 expired 처리).
    """
    changes = tuple(
        InstanceChange(
            instance_id=req.instance_id,
            payload_fields=req.payload.non_null_fields() if req.payload else {},
            label=req.label,
            lifecycle=(
                InstanceLifecycleState(
                    kind=req.lifecycle_kind,
                    # archive_reason 은 archived 전이에서만 의미 — 비-archived 에 끼면
                    # active 행에 reason 이 영속되는 도메인 위생 위반이라 무시한다 (리뷰 P2).
                    archive_reason=(
                        req.archive_reason
                        if req.lifecycle_kind is InstanceLifecycleKind.ARCHIVED
                        else None
                    ),
                )
                if req.lifecycle_kind is not None
                else None
            ),
        )
        for req in payload.instances
    )
    item = await UpdateMochiItem(repository=PostgresMochiItemRepository(db)).execute(
        UpdateMochiItemCommand(
            owner_id=user,
            mochi_item_id=mochi_item_id,
            text=payload.text,
            user_memo=payload.user_memo,
            summary=payload.summary,
            instance_changes=changes,
        )
    )
    await db.commit()
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


@router.post("/{mochi_item_id}/favorite", response_model=MochiItemResponse)
async def set_mochi_item_favorite(
    mochi_item_id: UUID,
    payload: FavoriteUpdateRequest,
    db: DBSession,
    user: CurrentUser,
) -> MochiItemResponse:
    """즐겨찾기 신호 set-state 토글 — 사용자가 검색 카드·상세에서 "중요"로 표시/해제한다.

    set-state 멱등(``isFavorite`` 같은 값 재전송은 no-op 200) — 응답 유실 재시도·빠른 더블탭이
    iOS 낙관적 업데이트를 오롤백하지 않게 한다. owner-scoped, 없는/다른 owner 항목은 404.
    """
    use_case = SetFavorite(repository=PostgresMochiItemRepository(db))
    item = await use_case.execute(
        SetFavoriteCommand(
            owner_id=user, mochi_item_id=mochi_item_id, is_favorite=payload.is_favorite
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
    await use_case.execute(DeleteMochiItemCommand(owner_id=user, mochi_item_id=mochi_item_id))
    await db.commit()
