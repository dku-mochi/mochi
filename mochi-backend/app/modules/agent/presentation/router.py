import json
from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from app.core.config import get_settings
from app.core.deps import DBSession, get_agent_llm
from app.core.error_envelope import NotFoundError
from app.core.security import CurrentUser
from app.modules.agent.application.orchestrator import AgentOrchestrator, StreamEvent
from app.modules.agent.infrastructure.registry import StaticToolRegistry
from app.modules.mochi_items.application.queries import GetMochiItemForOwner, make_mochi_item_repository

router = APIRouter(prefix="/mochi_items", tags=["agent"])


@router.get("/{mochi_item_id}/stream")
async def stream_agent_run(
    mochi_item_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> StreamingResponse:
    """SSE 스트림. MochiItem owner 가 아닌 경우 404로 응답한다 (자원 존재 노출 방지).

    스트림 포맷:
    ```
    event: node
    data: {"node":"normalized","run_id":"..."}

    event: final
    data: {"run_id":"...","tokens":1234}
    ```
    """
    item = await GetMochiItemForOwner(repository=make_mochi_item_repository(db)).execute(
        owner_id=user, mochi_item_id=mochi_item_id
    )
    if item is None:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")

    # progress shell — gateway/persistence 를 주입하지 않아 분석/write-back 을 하지 않는다.
    # 실제 분석은 outbox 워커가 단일 소유(이중 실행 방지). 이 엔드포인트는 노드 진행만 흘린다.
    # (iOS SSE 소비 + worker run 관찰(read-only) 배선은 후속 작업.)
    settings = get_settings()
    orchestrator = AgentOrchestrator(
        llm=get_agent_llm(),
        tools=StaticToolRegistry(),
        max_steps=settings.agent_max_steps,
    )

    async def event_source() -> AsyncIterator[bytes]:
        yield b": stream-open\n\n"
        try:
            async for event in orchestrator.run(mochi_item_id, user):
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
