"""/devices/* 라우터 — push 토큰 등록."""

from fastapi import APIRouter, status
from fastapi.responses import Response

from app.core.deps import DBSession
from app.core.error_envelope import NotFoundError
from app.core.security import CurrentUser
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)
from app.modules.notifications.application.register_push_token import (
    RegisterPushToken,
    RegisterPushTokenCommand,
)
from app.modules.notifications.infrastructure.repository import PostgresPushTokenRepository
from app.modules.notifications.presentation.schemas import RegisterPushTokenRequest

router = APIRouter(prefix="/devices", tags=["notifications"])


@router.post("/push-token", status_code=status.HTTP_204_NO_CONTENT)
async def register_push_token(
    payload: RegisterPushTokenRequest, db: DBSession, user: CurrentUser
) -> Response:
    """단말/Live Activity push 토큰 등록 (owner-scoped upsert).

    iOS AppDelegate(apns_device) + push-to-start observe(la_start)가 호출한다. 둘 다 owner 단위라
    mochiItemID 없이 등록한다.
    """
    # mochi_item_id 가 있으면 소유권을 강제한다(타 owner item UUID 로 등록·존재 탐지 차단). 현 등록
    # 경로(apns_device·la_start)는 owner 단위라 None 이라 미진입 — 구 per-item LA 토큰 호환 방어.
    if payload.mochi_item_id is not None:
        owned = await GetMochiItemForOwner(repository=make_mochi_item_repository(db)).execute(
            owner_id=user, mochi_item_id=payload.mochi_item_id
        )
        if owned is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")

    use_case = RegisterPushToken(tokens=PostgresPushTokenRepository(db))
    await use_case.execute(
        RegisterPushTokenCommand(
            owner_id=user,
            token=payload.token,
            token_type=payload.token_type,
            environment=payload.environment,
            mochi_item_id=payload.mochi_item_id,
        )
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
