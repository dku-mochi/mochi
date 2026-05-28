from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api import build_v1_router
from app.core.config import get_settings
from app.core.error_envelope import (
    DomainError,
    handle_domain_exception,
    handle_http_exception,
    handle_unhandled_exception,
    handle_validation_exception,
)
from app.core.logging import configure_logging, get_logger
from app.core.middleware import RequestContextMiddleware

log = get_logger("app")


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    configure_logging()
    log.info("app.startup")
    yield
    log.info("app.shutdown")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title=settings.app_name,
        version="0.1.0",
        debug=settings.debug,
        lifespan=lifespan,
    )

    app.add_middleware(RequestContextMiddleware)

    app.add_exception_handler(DomainError, handle_domain_exception)
    app.add_exception_handler(StarletteHTTPException, handle_http_exception)
    app.add_exception_handler(RequestValidationError, handle_validation_exception)
    app.add_exception_handler(Exception, handle_unhandled_exception)

    app.include_router(build_v1_router())
    return app


app = create_app()
