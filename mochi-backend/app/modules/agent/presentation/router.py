import json
from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from app.core.config import get_settings
from app.core.deps import DBSession
from app.core.error_envelope import NotFoundError
from app.core.security import CurrentUser
from app.modules.agent.application.orchestrator import AgentOrchestrator, StreamEvent
from app.modules.agent.infrastructure.registry import StaticToolRegistry
from app.modules.mochi_items.application.queries import GetCaptureForOwner, make_capture_repository

router = APIRouter(prefix="/captures", tags=["agent"])


@router.get("/{capture_id}/stream")
async def stream_agent_run(
    capture_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> StreamingResponse:
    """SSE 스트림. capture owner 가 아닌 경우 404로 응답한다 (자원 존재 노출 방지).

    스트림 포맷:
    ```
    event: node
    data: {"node":"normalized","run_id":"..."}

    event: final
    data: {"run_id":"...","tokens":1234}
    ```
    """
    capture = await GetCaptureForOwner(repository=make_capture_repository(db)).execute(
        owner_id=user, capture_id=capture_id
    )
    if capture is None:
        raise NotFoundError("Capture not found", code="capture.not_found")

    settings = get_settings()
    orchestrator = AgentOrchestrator(
        llm=_UnconfiguredLLM(),
        tools=StaticToolRegistry(),
        max_steps=settings.agent_max_steps,
    )

    async def event_source() -> AsyncIterator[bytes]:
        yield b": stream-open\n\n"
        try:
            async for event in orchestrator.run(capture_id):
                yield _serialize(event)
        except Exception as exc:  # noqa: BLE001
            err = StreamEvent("failed", {"message": str(exc), "run_id": "unknown"})
            yield _serialize(err)

    return StreamingResponse(
        event_source(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


def _serialize(event: StreamEvent) -> bytes:
    body = json.dumps(event.payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event.kind}\ndata: {body}\n\n".encode()


class _UnconfiguredLLM:
    """LLM이 주입되지 않은 상태에서 deterministic 시퀀스만 흘리는 placeholder."""

    async def stream(self, **_: object):
        if False:
            yield None  # type: ignore[unreachable]
