from typing import Any

from fastapi import Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.logging import get_logger

log = get_logger("error")


class ErrorEnvelope(BaseModel):
    """모든 4xx/5xx 응답이 따르는 통일 포맷. iOS `APIErrorEnvelope` 와 1:1 매칭."""

    code: str = Field(description="도트(.)로 구분된 도메인.사유 코드 — 예: capture.not_found")
    message: str
    request_id: str = Field(alias="requestId")
    retry_after: float | None = Field(default=None, alias="retryAfter")

    model_config = {"populate_by_name": True}


class DomainError(Exception):
    """비즈니스 도메인 에러의 부모 — 모든 핸들러는 이걸 잡아서 ErrorEnvelope으로 변환."""

    code: str = "domain.unknown"
    status_code: int = status.HTTP_400_BAD_REQUEST
    retry_after: float | None = None

    def __init__(self, message: str, *, code: str | None = None, retry_after: float | None = None):
        super().__init__(message)
        self.message = message
        if code:
            self.code = code
        if retry_after is not None:
            self.retry_after = retry_after


class NotFoundError(DomainError):
    code = "common.not_found"
    status_code = status.HTTP_404_NOT_FOUND


class UnauthorizedError(DomainError):
    code = "common.unauthorized"
    status_code = status.HTTP_401_UNAUTHORIZED


class RateLimitedError(DomainError):
    code = "common.rate_limited"
    status_code = status.HTTP_429_TOO_MANY_REQUESTS


def _request_id_from(request: Request) -> str:
    return getattr(request.state, "request_id", "unknown")


def _envelope_response(*, status_code: int, code: str, message: str, request_id: str, retry_after: float | None = None) -> JSONResponse:
    envelope = ErrorEnvelope(code=code, message=message, request_id=request_id, retry_after=retry_after)
    headers: dict[str, Any] = {"X-Mochi-Request-ID": request_id}
    if retry_after is not None:
        headers["Retry-After"] = str(int(retry_after))
    return JSONResponse(status_code=status_code, content=envelope.model_dump(by_alias=True), headers=headers)


async def handle_domain_exception(request: Request, exc: DomainError) -> JSONResponse:
    request_id = _request_id_from(request)
    log.warning(
        "domain.error",
        code=exc.code,
        message=exc.message,
        request_id=request_id,
        status_code=exc.status_code,
    )
    return _envelope_response(
        status_code=exc.status_code,
        code=exc.code,
        message=exc.message,
        request_id=request_id,
        retry_after=exc.retry_after,
    )


async def handle_http_exception(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    request_id = _request_id_from(request)
    return _envelope_response(
        status_code=exc.status_code,
        code=f"http.{exc.status_code}",
        message=str(exc.detail),
        request_id=request_id,
    )


async def handle_validation_exception(request: Request, exc: RequestValidationError) -> JSONResponse:
    request_id = _request_id_from(request)
    return _envelope_response(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        code="common.validation_failed",
        message=str(exc.errors()[:3]),
        request_id=request_id,
    )


async def handle_unhandled_exception(request: Request, exc: Exception) -> JSONResponse:
    request_id = _request_id_from(request)
    log.error("internal.error", request_id=request_id, exception=str(exc), exc_info=exc)
    return _envelope_response(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        code="common.internal",
        message="Internal Server Error",
        request_id=request_id,
    )


# Convenience used to mark "not implemented" without leaking 501 to the client.
class FeatureUnavailableError(DomainError):
    code = "common.feature_unavailable"
    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
