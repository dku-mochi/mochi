import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress

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
from app.modules.agent.application.mochi_item_worker import MochiItemWorker

log = get_logger("app")


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    configure_logging()
    log.info("app.startup")
    settings = get_settings()
    worker = MochiItemWorker(max_steps=settings.agent_max_steps)
    worker_task = asyncio.create_task(worker.run_forever())
    log.info("worker.started")
    try:
        yield
    finally:
        await worker.stop()
        worker_task.cancel()
        with suppress(asyncio.CancelledError):
            await worker_task
        log.info("worker.stopped")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title=settings.app_name,
        version="0.1.0",
        debug=settings.debug,
        lifespan=lifespan,
    )

    app.add_middleware(RequestContextMiddleware)

    app.add_exception_handler(DomainError, handle_domain_exception)  # type: ignore[arg-type]
    app.add_exception_handler(StarletteHTTPException, handle_http_exception)  # type: ignore[arg-type]
    app.add_exception_handler(RequestValidationError, handle_validation_exception)  # type: ignore[arg-type]
    app.add_exception_handler(Exception, handle_unhandled_exception)

    app.include_router(build_v1_router())
    return app


app = create_app()
