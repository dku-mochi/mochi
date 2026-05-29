"""/auth/* + /users/me 라우터."""

from typing import Annotated

from fastapi import APIRouter, Header, status
from fastapi.responses import Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.deps import DBSession
from app.core.error_envelope import FeatureUnavailableError, NotFoundError
from app.core.security import CurrentUser
from app.modules.auth.application.dev_sign_in import DevSignIn, DevSignInCommand
from app.modules.auth.application.logout import Logout, LogoutCommand
from app.modules.auth.application.refresh import RefreshCommand, RotateRefreshToken
from app.modules.auth.application.sign_in import (
    AppleSignInCommand,
    GoogleSignInCommand,
    SignIn,
    SignInResult,
)
from app.modules.auth.infrastructure.providers import (
    get_access_token_issuer,
    get_id_token_verifier,
    get_refresh_token_issuer,
)
from app.modules.auth.infrastructure.repository import (
    PostgresRefreshTokenRepository,
    PostgresUserRepository,
)
from app.modules.auth.presentation.schemas import (
    AppleSignInRequest,
    DevSignInRequest,
    GoogleSignInRequest,
    LogoutRequest,
    RefreshRequest,
    SignInResponse,
    TokensResponse,
    UserResponse,
)

auth_router = APIRouter(prefix="/auth", tags=["auth"])
users_router = APIRouter(prefix="/users", tags=["users"])


def _build_sign_in(db: AsyncSession) -> SignIn:
    return SignIn(
        verifier=get_id_token_verifier(),
        users=PostgresUserRepository(db),
        refresh_tokens=PostgresRefreshTokenRepository(db),
        access_issuer=get_access_token_issuer(),
        refresh_issuer=get_refresh_token_issuer(),
    )


def _build_rotate(db: AsyncSession) -> RotateRefreshToken:
    return RotateRefreshToken(
        refresh_tokens=PostgresRefreshTokenRepository(db),
        users=PostgresUserRepository(db),
        access_issuer=get_access_token_issuer(),
        refresh_issuer=get_refresh_token_issuer(),
    )


def _build_logout(db: AsyncSession) -> Logout:
    return Logout(
        refresh_tokens=PostgresRefreshTokenRepository(db),
        refresh_issuer=get_refresh_token_issuer(),
    )


def _build_dev_sign_in(db: AsyncSession) -> DevSignIn:
    return DevSignIn(
        users=PostgresUserRepository(db),
        refresh_tokens=PostgresRefreshTokenRepository(db),
        access_issuer=get_access_token_issuer(),
        refresh_issuer=get_refresh_token_issuer(),
    )


def _to_response(result: SignInResult) -> SignInResponse:
    return SignInResponse(
        user=UserResponse(
            id=result.user.id,
            email=result.user.email,
            display_name=result.user.display_name,
            locale=result.user.locale,
            onboarding_completed_at=result.user.onboarding_completed_at,
        ),
        tokens=TokensResponse(
            access_token=result.tokens.access_token,
            access_token_expires_at=result.tokens.access_token_expires_at,
            refresh_token=result.tokens.refresh_token,
            refresh_token_expires_at=result.tokens.refresh_token_expires_at,
        ),
        is_new_user=result.was_signup,
    )


@auth_router.post("/apple", response_model=SignInResponse)
async def sign_in_with_apple(
    payload: AppleSignInRequest,
    db: DBSession,
    user_agent: Annotated[str | None, Header(alias="User-Agent")] = None,
) -> SignInResponse:
    use_case = _build_sign_in(db)
    result = await use_case.with_apple(
        AppleSignInCommand(
            id_token=payload.id_token,
            nonce_raw=payload.raw_nonce,
            full_name=payload.full_name,
            device_label=payload.device_label,
            user_agent=user_agent,
        )
    )
    await db.commit()
    return _to_response(result)


@auth_router.post("/google", response_model=SignInResponse)
async def sign_in_with_google(
    payload: GoogleSignInRequest,
    db: DBSession,
    user_agent: Annotated[str | None, Header(alias="User-Agent")] = None,
) -> SignInResponse:
    use_case = _build_sign_in(db)
    result = await use_case.with_google(
        GoogleSignInCommand(
            id_token=payload.id_token,
            device_label=payload.device_label,
            user_agent=user_agent,
        )
    )
    await db.commit()
    return _to_response(result)


@auth_router.post("/dev", response_model=SignInResponse)
async def sign_in_dev(
    payload: DevSignInRequest,
    db: DBSession,
    user_agent: Annotated[str | None, Header(alias="User-Agent")] = None,
) -> SignInResponse:
    """로컬 개발용 임시 로그인. ``environment=local`` 에서만 응답한다.

    iOS의 "임시 로그인" 버튼이 호출한다. Apple/Google JWKS 검증을 거치지 않고
    subject 만으로 결정론적 user 를 만들고 자체 access/refresh JWT 를 발급한다.
    """

    if get_settings().environment != "local":
        raise FeatureUnavailableError(
            "Dev sign-in is only available in local environment",
            code="auth.dev_sign_in_disabled",
        )

    use_case = _build_dev_sign_in(db)
    result = await use_case.execute(
        DevSignInCommand(
            subject=payload.subject,
            display_name=payload.display_name,
            device_label=payload.device_label,
            user_agent=user_agent,
        )
    )
    await db.commit()
    return _to_response(result)


@auth_router.post("/refresh", response_model=TokensResponse)
async def refresh_tokens(
    payload: RefreshRequest,
    db: DBSession,
    user_agent: Annotated[str | None, Header(alias="User-Agent")] = None,
) -> TokensResponse:
    use_case = _build_rotate(db)
    tokens = await use_case.execute(
        RefreshCommand(
            raw_refresh_token=payload.refresh_token,
            device_label=payload.device_label,
            user_agent=user_agent,
        )
    )
    await db.commit()
    return TokensResponse(
        access_token=tokens.access_token,
        access_token_expires_at=tokens.access_token_expires_at,
        refresh_token=tokens.refresh_token,
        refresh_token_expires_at=tokens.refresh_token_expires_at,
    )


@auth_router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(payload: LogoutRequest, db: DBSession) -> Response:
    use_case = _build_logout(db)
    await use_case.execute(LogoutCommand(raw_refresh_token=payload.refresh_token))
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@users_router.get("/me", response_model=UserResponse)
async def get_me(db: DBSession, user: CurrentUser) -> UserResponse:
    repo = PostgresUserRepository(db)
    found = await repo.find_user(user_id=user)
    if found is None:
        # dev token 모드로 인증한 경우 users 행이 없을 수 있다 → 404.
        raise NotFoundError("User not found", code="user.not_found")
    if found.deleted_at is not None:
        raise NotFoundError("User has been deleted", code="user.deleted")
    return UserResponse(
        id=found.id,
        email=found.email,
        display_name=found.display_name,
        locale=found.locale,
        onboarding_completed_at=found.onboarding_completed_at,
    )
