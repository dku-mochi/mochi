import asyncio
import json
from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from app.core.config import get_settings
from app.core.db import get_session_factory
from app.core.deps import DBSession
from app.core.error_envelope import NotFoundError
from app.core.security import CurrentUser
from app.modules.mochi_items.application.queries import GetMochiItemForOwner, make_mochi_item_repository

router = APIRouter(prefix="/mochi_items", tags=["agent"])

# foreground SSE 내부 폴링 — 클라 3초 폴링을 대체하므로 더 촘촘히. worker 와 DB 만 공유(IPC 없음).
_POLL_INTERVAL_SECONDS = 1.0


@router.get("/{mochi_item_id}/stream")
async def stream_agent_run(
    mochi_item_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> StreamingResponse:
    """SSE 스트림 — worker 의 실제 분석 진행(``mochi_items.lifecycle_kind``)을 관찰해 흘린다.

    foreground 클라가 폴링 대신 이 스트림을 구독한다. 백엔드는 처리상태 전이(``node``)와
    완료/실패 신호만 흘리고, **분석 결과 자체는 보내지 않는다** — 클라가 ``final`` 수신 시
    ``GET /mochi_items/{id}`` 로 재조회한다(이중 직렬화 회피, PR-B 결정).

    실제 분석은 outbox 워커가 단일 소유한다(이중 실행 방지). 이 엔드포인트는 read-only 관찰자다.
    owner 가 아니면 404 (자원 존재 노출 방지).

    스트림 포맷:
    ```
    event: node
    data: {"mochi_item_id":"...","lifecycle_kind":"analyzing"}

    event: final
    data: {"mochi_item_id":"...","lifecycle_kind":"analyzed"}
    ```
    """
    item = await GetMochiItemForOwner(repository=make_mochi_item_repository(db)).execute(
        owner_id=user, mochi_item_id=mochi_item_id
    )
    if item is None:
        raise NotFoundError("Mochi item not found", code="mochi_item.not_found")

    settings = get_settings()
    # SSE 상한 ≥ worker 분석 상한 + 여유 — worker 진행 중 스트림이 먼저 닫혀 완료신호를 놓치지 않게.
    deadline_seconds = settings.agent_total_timeout_seconds + 30.0

    async def event_source() -> AsyncIterator[bytes]:
        yield b": stream-open\n\n"
        last_kind: str | None = None
        waited = 0.0
        while True:
            # 폴링마다 새 세션 — request 세션을 재사용하면 identity-map 캐시로 lifecycle 변화를 못 본다.
            async with get_session_factory()() as poll_session:
                current = await GetMochiItemForOwner(
                    repository=make_mochi_item_repository(poll_session)
                ).execute(owner_id=user, mochi_item_id=mochi_item_id)
            kind = current.lifecycle.kind.value if current else "failed"

            if kind != last_kind:
                last_kind = kind
                if kind == "analyzed":
                    yield _sse("final", {"mochi_item_id": str(mochi_item_id), "lifecycle_kind": kind})
                    return
                if kind == "failed":
                    reason = (current.lifecycle.failure_reason if current else None) or "failed"
                    yield _sse("failed", {"mochi_item_id": str(mochi_item_id), "message": reason})
                    return
                yield _sse("node", {"mochi_item_id": str(mochi_item_id), "lifecycle_kind": kind})

            if waited >= deadline_seconds:
                # 분석은 worker 가 계속 — SSE 만 닫힘. iOS 폴링 fallback 이 메운다.
                yield _sse("failed", {"mochi_item_id": str(mochi_item_id), "message": "stream_timeout"})
                return
            await asyncio.sleep(_POLL_INTERVAL_SECONDS)
            waited += _POLL_INTERVAL_SECONDS

    return StreamingResponse(
        event_source(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


def _sse(event: str, data: dict[str, str]) -> bytes:
    body = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {body}\n\n".encode()
