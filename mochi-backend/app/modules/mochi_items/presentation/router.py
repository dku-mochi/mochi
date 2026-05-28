import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Form, Header, UploadFile, status

from app.core.deps import DBSession, IntentClassifierDep
from app.core.error_envelope import DomainError, NotFoundError
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
from app.modules.mochi_items.domain.entities import ImageRef, MochiItem
from app.modules.mochi_items.infrastructure.outbox import OutboxNotifier
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.modules.mochi_items.presentation.schemas import (
    BackTapMochiItemResponse,
    ImageRefResponse,
    IntentCandidateResponse,
    IntentOverrideRequest,
    MochiItemCreateRequest,
    MochiItemResponse,
)

router = APIRouter(prefix="/mochi_items", tags=["mochi_items"])

# 백탭 캡쳐 이미지 상한 — JPEG q60 의 ~5x buffer (lab 측정에선 평균 ~85KB).
_BACK_TAP_MAX_BYTES = 5 * 1024 * 1024
_BACK_TAP_ALLOWED_MIME = ("image/jpeg", "image/png")


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
    response_model=BackTapMochiItemResponse,
)
async def create_back_tap_mochi_item(
    db: DBSession,
    user: CurrentUser,
    classifier: IntentClassifierDep,
    image: Annotated[UploadFile, File(description="JPEG/PNG screenshot binary")],
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    user_memo: Annotated[str | None, Form(alias="userMemo")] = None,
) -> BackTapMochiItemResponse:
    """백탭 캡쳐 — Gemini 로 의도 후보 3개 도출 후 MochiItem 즉시 적재.

    응답의 ``candidates`` 가 알림 UX (top-1 강조 + 펼침 시 multi-select) 의 원천이다.
    사용자가 다른 의도를 고르면 ``PATCH /mochi_items/{id}/intent`` 로 primary 교체.
    """

    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for MochiItem ingestion",
            code="mochi_item.missing_idempotency_key",
        )
    if image.content_type not in _BACK_TAP_ALLOWED_MIME:
        raise DomainError(
            f"Unsupported image content_type {image.content_type!r}; expected JPEG/PNG",
            code="mochi_item.unsupported_image_type",
        )

    image_bytes = await image.read()
    byte_size = len(image_bytes)
    if byte_size == 0:
        raise DomainError("Image payload is empty", code="mochi_item.empty_image")
    if byte_size > _BACK_TAP_MAX_BYTES:
        raise DomainError(
            f"Image too large: {byte_size} bytes > {_BACK_TAP_MAX_BYTES}",
            code="mochi_item.image_too_large",
        )

    sha256 = hashlib.sha256(image_bytes).hexdigest()

    use_case = BackTapIngest(
        repository=PostgresMochiItemRepository(db),
        notifier=OutboxNotifier(db),
        classifier=classifier,
    )
    result = await use_case.execute(
        BackTapIngestCommand(
            owner_id=user,
            idempotency_key=idempotency_key,
            image=image_bytes,
            mime_type=image.content_type,
            byte_size=byte_size,
            sha256=sha256,
            user_memo=user_memo,
        )
    )
    await db.commit()

    return BackTapMochiItemResponse(
        item=_to_response(result.item),
        candidates=[
            IntentCandidateResponse(
                label=c.label,
                intent=c.intent,
                applicability=c.applicability,
                reasoning=c.reasoning,
            )
            for c in result.candidates
        ],
        was_replay=result.was_idempotent_replay,
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


@router.get("/{mochi_item_id}", response_model=MochiItemResponse)
async def get_mochi_item(mochi_item_id: UUID, db: DBSession, user: CurrentUser) -> MochiItemResponse:
    repo = PostgresMochiItemRepository(db)
    item = await repo.find_by_id(owner_id=user, mochi_item_id=mochi_item_id)
    if not item:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
    return _to_response(item)
