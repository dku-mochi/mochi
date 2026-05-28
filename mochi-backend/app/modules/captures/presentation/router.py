import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Form, Header, UploadFile, status

from app.core.deps import DBSession, IntentClassifierDep
from app.core.error_envelope import DomainError, NotFoundError
from app.core.security import CurrentUser
from app.modules.captures.application.back_tap_capture import (
    BackTapCapture,
    BackTapCaptureCommand,
)
from app.modules.captures.application.ingest_capture import IngestCapture, IngestCaptureCommand
from app.modules.captures.application.override_capture_intent import (
    OverrideCaptureIntent,
    OverrideIntentCommand,
)
from app.modules.captures.domain.entities import Capture, ImageRef
from app.modules.captures.infrastructure.outbox import OutboxNotifier
from app.modules.captures.infrastructure.repository import PostgresCaptureRepository
from app.modules.captures.presentation.schemas import (
    BackTapCaptureResponse,
    CaptureCreateRequest,
    CaptureResponse,
    ImageRefResponse,
    IntentCandidateResponse,
    IntentOverrideRequest,
)

router = APIRouter(prefix="/captures", tags=["captures"])

# 백탭 캡쳐 이미지 상한 — JPEG q60 의 ~5x buffer (lab 측정에선 평균 ~85KB).
_BACK_TAP_MAX_BYTES = 5 * 1024 * 1024
_BACK_TAP_ALLOWED_MIME = ("image/jpeg", "image/png")


def _to_response(capture: Capture) -> CaptureResponse:
    return CaptureResponse(
        id=capture.id,
        channel=capture.source.channel,
        url=capture.source.url,
        text=capture.source.text,
        user_memo=capture.source.user_memo,
        intent=capture.intent,
        secondary_intents=list(capture.secondary_intents),
        intent_applicability={i.value: v for i, v in capture.intent_applicability.items()},
        summary=capture.summary,
        importance=capture.importance,
        confidence=capture.confidence,
        lifecycle_kind=capture.lifecycle.kind.value,
        sync_kind=capture.sync.kind,
        image_refs=[
            ImageRefResponse(
                object_key=img.object_key,
                mime_type=img.mime_type,
                byte_size=img.byte_size,
                sha256=img.sha256,
            )
            for img in capture.source.image_refs
        ],
        captured_at=capture.source.captured_at,
        created_at=capture.created_at,
    )


@router.post("", status_code=status.HTTP_201_CREATED, response_model=CaptureResponse)
async def create_capture(
    payload: CaptureCreateRequest,
    db: DBSession,
    user: CurrentUser,
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> CaptureResponse:
    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for capture ingestion",
            code="capture.missing_idempotency_key",
        )

    use_case = IngestCapture(
        repository=PostgresCaptureRepository(db),
        notifier=OutboxNotifier(db),
    )
    result = await use_case.execute(
        IngestCaptureCommand(
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
    return _to_response(result.capture)


@router.post(
    "/back-tap",
    status_code=status.HTTP_201_CREATED,
    response_model=BackTapCaptureResponse,
)
async def create_back_tap_capture(
    db: DBSession,
    user: CurrentUser,
    classifier: IntentClassifierDep,
    image: Annotated[UploadFile, File(description="JPEG/PNG screenshot binary")],
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    user_memo: Annotated[str | None, Form(alias="userMemo")] = None,
) -> BackTapCaptureResponse:
    """백탭 캡쳐 — Gemini 로 의도 후보 3개 도출 후 capture 즉시 적재.

    응답의 ``candidates`` 가 알림 UX (top-1 강조 + 펼침 시 multi-select) 의 원천이다.
    사용자가 다른 의도를 고르면 ``PATCH /captures/{id}/intent`` 로 primary 교체.
    """

    if not idempotency_key:
        raise DomainError(
            "Idempotency-Key header is required for capture ingestion",
            code="capture.missing_idempotency_key",
        )
    if image.content_type not in _BACK_TAP_ALLOWED_MIME:
        raise DomainError(
            f"Unsupported image content_type {image.content_type!r}; expected JPEG/PNG",
            code="capture.unsupported_image_type",
        )

    image_bytes = await image.read()
    byte_size = len(image_bytes)
    if byte_size == 0:
        raise DomainError("Image payload is empty", code="capture.empty_image")
    if byte_size > _BACK_TAP_MAX_BYTES:
        raise DomainError(
            f"Image too large: {byte_size} bytes > {_BACK_TAP_MAX_BYTES}",
            code="capture.image_too_large",
        )

    sha256 = hashlib.sha256(image_bytes).hexdigest()

    use_case = BackTapCapture(
        repository=PostgresCaptureRepository(db),
        notifier=OutboxNotifier(db),
        classifier=classifier,
    )
    result = await use_case.execute(
        BackTapCaptureCommand(
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

    return BackTapCaptureResponse(
        capture=_to_response(result.capture),
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


@router.patch("/{capture_id}/intent", response_model=CaptureResponse)
async def override_capture_intent(
    capture_id: UUID,
    payload: IntentOverrideRequest,
    db: DBSession,
    user: CurrentUser,
) -> CaptureResponse:
    use_case = OverrideCaptureIntent(repository=PostgresCaptureRepository(db))
    capture = await use_case.execute(
        OverrideIntentCommand(
            owner_id=user,
            capture_id=capture_id,
            new_primary=payload.intent,
        )
    )
    await db.commit()
    return _to_response(capture)


@router.get("/{capture_id}", response_model=CaptureResponse)
async def get_capture(capture_id: UUID, db: DBSession, user: CurrentUser) -> CaptureResponse:
    repo = PostgresCaptureRepository(db)
    capture = await repo.find_by_id(owner_id=user, capture_id=capture_id)
    if not capture:
        raise NotFoundError("Capture not found", code="capture.not_found")
    return _to_response(capture)
