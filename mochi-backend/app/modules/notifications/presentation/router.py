"""/devices/* 라우터 — push 토큰 등록."""

from fastapi import APIRouter, status
from fastapi.responses import Response

from app.core.deps import DBSession
from app.core.error_envelope import DomainError, NotFoundError
from app.core.security import CurrentUser
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)
from app.modules.notifications.application.register_push_token import (
    RegisterPushToken,
    RegisterPushTokenCommand,
)
from app.modules.notifications.domain.entities import PushTokenType
from app.modules.notifications.infrastructure.repository import PostgresPushTokenRepository
from app.modules.notifications.presentation.schemas import RegisterPushTokenRequest

router = APIRouter(prefix="/devices", tags=["notifications"])


@router.post("/push-token", status_code=status.HTTP_204_NO_CONTENT)
async def register_push_token(
    payload: RegisterPushTokenRequest, db: DBSession, user: CurrentUser
) -> Response:
    """단말/Live Activity push 토큰 등록 (owner-scoped upsert).

    iOS AppDelegate(apns_device) + LiveActivityCoordinator(live_activity)가 호출한다.
    """
    # LA 토큰은 mochi_item 1:1 — mochiItemID 필수(없으면 _notify 가 item id 로 조회 못 해 영영 미사용).
    if payload.token_type == PushTokenType.LIVE_ACTIVITY and payload.mochi_item_id is None:
        raise DomainError(
            "live_activity token requires mochiItemID",
            code="push_token.missing_mochi_item_id",
        )
    # mochi_item_id 가 있으면 소유권을 강제한다(타 owner item UUID 로 등록·존재 탐지 차단).
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
