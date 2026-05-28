import uuid

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from app.core.logging import bind_contextvars, clear_contextvars, get_logger

log = get_logger("middleware")

REQUEST_ID_HEADER = "X-Mochi-Request-ID"
IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"


class RequestContextMiddleware(BaseHTTPMiddleware):
    """모든 요청에 request_id를 부여하고 structlog context에 바인딩.

    - 클라이언트가 보낸 `X-Mochi-Request-ID` 가 있으면 그대로 사용 (분산 trace 연속성)
    - 없으면 새 UUID 생성
    - 응답 헤더에도 동일 값 echo
    """

    async def dispatch(self, request: Request, call_next):  # type: ignore[override]
        request_id = request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex
        idempotency_key = request.headers.get(IDEMPOTENCY_KEY_HEADER)

        request.state.request_id = request_id
        request.state.idempotency_key = idempotency_key

        bind_contextvars(
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            idempotency_key=idempotency_key,
        )
        log.info("request.started")
        try:
            response: Response = await call_next(request)
        finally:
            clear_contextvars()

        response.headers[REQUEST_ID_HEADER] = request_id
        return response
