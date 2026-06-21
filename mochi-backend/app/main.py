import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress

from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

load_dotenv()

from app.api import build_v1_router
from app.core.config import Settings, get_settings
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
from app.modules.auth.infrastructure.jwt_issuer import HS256AccessTokenIssuer
from app.modules.notifications.application.notification_worker import NotificationWorker

log = get_logger("app")


def _verify_startup_safety(settings: Settings) -> None:
    """부팅 시 치명적 auth 오설정을 fail-fast.

    1. access JWT secret 을 즉시 검증한다 — 누락·약함·운영에 dev 기본값이면 첫 로그인이 아니라 부팅에서 실패.
    2. ``environment=local`` 인데 운영용 secret 이 주입돼 있으면 ENVIRONMENT 누락으로 보고 부팅을 거부한다 —
       local 은 dev 토큰·dev sign-in·well-known dev secret 을 허용하는 permissive 모드라, 실사용자가 붙는
       배포가 실수로 local 로 뜨면 완전한 auth bypass 가 된다(fail-open 차단).
    """
    issuer = HS256AccessTokenIssuer(settings)
    issuer.validate()
    if settings.environment == "local":
        if not issuer.is_using_dev_default_secret():
            raise RuntimeError(
                "environment=local 인데 운영용 AUTH_ACCESS_SECRET 이 주입됐습니다 — ENVIRONMENT 누락으로 보입니다. "
                "운영/스테이징 배포라면 ENVIRONMENT=production(또는 staging) 으로 설정하세요 "
                "(local 은 dev 토큰·dev sign-in 을 허용하는 permissive 모드입니다)."
            )
        log.warning("auth.dev_mode_active", environment=settings.environment)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    configure_logging()
    log.info("app.startup")
    settings = get_settings()
    _verify_startup_safety(settings)
    workers = [
        MochiItemWorker(max_steps=settings.agent_max_steps) for _ in range(settings.worker_concurrency)
    ]
    worker_tasks = [asyncio.create_task(w.run_forever()) for w in workers]
    log.info("worker.started", count=settings.worker_concurrency)
    # 능동 회수 알림 cron 워커 1 인스턴스. killswitch=False 여도 기동은 하고 루프가 no-op.
    recall_worker = NotificationWorker()
    recall_task = asyncio.create_task(recall_worker.run_forever())
    log.info("recall_worker.started")
    try:
        yield
    finally:
        for w in workers:
            await w.stop()
        await recall_worker.stop()
        for task in worker_tasks:
            task.cancel()
        recall_task.cancel()
        for task in worker_tasks:
            with suppress(asyncio.CancelledError):
                await task
        with suppress(asyncio.CancelledError):
            await recall_task
        log.info("worker.stopped", count=len(worker_tasks))


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
