"""/conversations 라우터 — 채팅 세션 목록·스냅샷·삭제 + 메시지 전송(POST-as-SSE).

메시지 전송은 응답이 곧 SSE 스트림이다 — 202+별도 GET 분리안은 구독 전 이벤트 유실
레이스로 기각(journal 2026-06-10). agent run 은 detached task 로 분리돼 클라이언트가
끊겨도 완주하고, 복귀는 ``GET /{id}/messages`` 스냅샷 재조회가 담당한다.
"""

import asyncio
import json
from collections.abc import AsyncIterator, Callable
from functools import lru_cache
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Query, status
from fastapi.responses import Response, StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import get_settings
from app.core.db import get_session_factory
from app.core.deps import DBSession, get_chat_llm, get_voyage_client
from app.core.error_envelope import ConflictError, DomainError, NotFoundError
from app.core.security import CurrentUser
from app.modules.agent.application.tool_factories import make_web_fetch_tool
from app.modules.conversations.application.begin_chat_turn import (
    BeginChatTurn,
    RunInProgressError,
)
from app.modules.conversations.application.queries import (
    DeleteConversation,
    GetConversationSnapshot,
    ListConversations,
    SetProposalStatus,
    make_conversation_repository,
)
from app.modules.conversations.application.run_chat_turn import RunChatTurn
from app.modules.conversations.domain.ports import ChatTool
from app.modules.conversations.domain.run_events import ChatEvent
from app.modules.conversations.infrastructure.run_registry import get_run_registry
from app.modules.conversations.infrastructure.tools.get_item_detail import GetItemDetailTool
from app.modules.conversations.infrastructure.tools.propose import (
    ProposeCreateMemoTool,
    ProposeCreateScheduleTool,
    ProposeItemDeleteTool,
    ProposeItemUpdateTool,
    ProposeReminderTool,
    make_item_reader,
)
from app.modules.conversations.infrastructure.tools.search_items import SearchItemsTool
from app.modules.conversations.infrastructure.tools.view_item_image import ViewItemImageTool
from app.modules.conversations.infrastructure.tools.web_fetch import WebFetchChatTool
from app.modules.conversations.infrastructure.tools.web_search import WebSearchTool
from app.modules.conversations.infrastructure.turn_store import SessionChatTurnStore
from app.modules.conversations.presentation.schemas import (
    ConversationListResponse,
    ConversationResponse,
    ConversationSnapshotResponse,
    MessageResponse,
    ProposalStatusUpdateRequest,
    SendMessageRequest,
)
from app.modules.conversations.prompts.chat_prompts import ACTIVE_CHAT_PROMPT
from app.shared.voyage import VoyageClient

router = APIRouter(prefix="/conversations", tags=["conversations"])

# detached run task 의 강한 참조 — 없으면 GC 가 진행 중 task 를 수거할 수 있다 (asyncio 명세).
_RUNNING_TASKS: set[asyncio.Task[None]] = set()


def _build_chat_tools(
    session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession],
    *,
    tavily_api_key: str | None,
    gcs_capture_bucket: str | None,
    voyage: VoyageClient | None = None,
) -> tuple[ChatTool, ...]:
    """**전부 read-only**. propose_* 도 검증 후 카드 payload 만 반환할 뿐 DB 를 쓰지
    않는다(실행은 사용자 확정 탭 → REST). 쓰기 가능한 툴을 여기 추가하는 것은 금지 —
    ``test_router_tool_registry_is_read_only`` 가 고정.

    web_search 는 키 미설정 시 제외(키 발급이 머지를 블록하지 않게 — journal
    2026-06-10), web_fetch 는 기록 속 링크 읽기에도 쓰여 키 없이 항상 등록.
    view_item_image 는 버킷 미설정 시 제외 — 등록해두고 항상 "no image" 를 돌려주면
    모델을 오도한다 (web_search 와 같은 원리).
    voyage 는 search_items 의 의미검색·리랭크용 — 미설정 시 키워드 단독 degrade."""
    item_reader = make_item_reader(session_factory)
    tools: list[ChatTool] = [
        SearchItemsTool(session_factory, voyage=voyage),
        GetItemDetailTool(session_factory),
        ProposeItemUpdateTool(item_reader),
        ProposeItemDeleteTool(item_reader),
        ProposeCreateScheduleTool(),
        ProposeReminderTool(),
        ProposeCreateMemoTool(),
        WebFetchChatTool(make_web_fetch_tool()),
    ]
    if gcs_capture_bucket:
        tools.append(ViewItemImageTool(item_reader, bucket=gcs_capture_bucket))
    if tavily_api_key:
        tools.append(WebSearchTool(tavily_api_key))
    return tuple(tools)


@lru_cache(maxsize=1)
def _chat_tools() -> tuple[ChatTool, ...]:
    """프로세스당 1회 조립 — 구성 규칙은 ``_build_chat_tools`` docstring 참고."""
    settings = get_settings()
    return _build_chat_tools(
        get_session_factory(),
        tavily_api_key=settings.tavily_api_key,
        gcs_capture_bucket=settings.gcs_capture_bucket,
        voyage=get_voyage_client(),
    )


def _sse(event: ChatEvent) -> bytes:
    body = json.dumps(event.payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event.kind}\ndata: {body}\n\n".encode()


@router.post("/{conversation_id}/messages")
async def send_message(
    conversation_id: UUID, payload: SendMessageRequest, db: DBSession, user: CurrentUser
) -> StreamingResponse:
    """메시지 전송 — 응답이 곧 run 의 SSE 스트림 (POST-as-SSE).

    conversationID 는 클라이언트 생성 — 첫 메시지가 대화를 암묵 생성한다. 동일 대화에
    진행 중 run 이 있으면 409(`conversation.run_in_progress`). 클라이언트가 중간에 끊겨도
    run 은 완주하며 모든 단계가 영속된다 — 복귀 시 스냅샷 재조회.

    이벤트 wire format (서버 정본 — ARCHITECTURE §3.6, iOS `ChatStreamEvent` 와 1:1.
    모든 payload 에 ``run_id`` 동봉):
    ```
    message_delta  {run_id, text}
    tool_started   {run_id, name, label}
    tool_finished  {run_id, name, summary}
    citation       {run_id, index, item_id, title, snippet}
    proposal       {run_id, id, type, payload}        (type: item_update|item_delete|create_schedule|reminder|create_memo)
    done           {run_id, message_id}               (assistant 메시지 행 id)
    error          {run_id, code, message}
    ```
    """
    text = payload.text.strip()
    if not text:
        # 공백만 — pydantic min_length 는 통과하므로 여기서 400.
        raise DomainError("empty message", code="conversation.empty_message")
    try:
        user_message = await BeginChatTurn(repository=make_conversation_repository(db)).execute(
            owner_id=user, conversation_id=conversation_id, text=text
        )
    except RunInProgressError as exc:
        raise ConflictError(
            "A run is already in progress for this conversation",
            code="conversation.run_in_progress",
        ) from exc
    await db.commit()

    registry = get_run_registry()
    run_id = user_message.run_id
    assert run_id is not None  # BeginChatTurn 이 항상 채운다
    queue = registry.create(run_id)

    runner = RunChatTurn(
        llm=get_chat_llm(),
        tools=list(_chat_tools()),
        store=SessionChatTurnStore(get_session_factory()),
        registry=registry,
        prompt=ACTIVE_CHAT_PROMPT,
        timeout_seconds=get_settings().chat_run_timeout_seconds,
    )
    task = asyncio.create_task(
        runner.execute(owner_id=user, conversation_id=conversation_id, run_id=run_id)
    )
    _RUNNING_TASKS.add(task)
    task.add_done_callback(_RUNNING_TASKS.discard)

    async def relay() -> AsyncIterator[bytes]:
        yield b": stream-open\n\n"
        while True:
            event: Any = await queue.get()
            if event is None:  # close sentinel — run 종료
                return
            yield _sse(event)

    return StreamingResponse(
        relay(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.get("", response_model=ConversationListResponse)
async def list_conversations(
    db: DBSession, user: CurrentUser, limit: int = Query(default=50, ge=1, le=100)
) -> ConversationListResponse:
    """히스토리 시트 — owner 의 살아있는 대화를 마지막 메시지 시각 내림차순으로."""
    conversations = await ListConversations(repository=make_conversation_repository(db)).execute(
        owner_id=user, limit=limit
    )
    return ConversationListResponse(
        conversations=[ConversationResponse.from_entity(c) for c in conversations]
    )


@router.get("/{conversation_id}/messages", response_model=ConversationSnapshotResponse)
async def get_conversation_snapshot(
    conversation_id: UUID, db: DBSession, user: CurrentUser
) -> ConversationSnapshotResponse:
    """대화 메시지 전체 스냅샷 — iOS 포그라운드 복귀·히스토리 재진입용.

    stale running run(서버 재시작으로 유실)은 이 읽기 시점에 failed 로 lazy repair 되므로
    클라이언트는 항상 정합한 run 상태를 본다.
    """
    snapshot = await GetConversationSnapshot(repository=make_conversation_repository(db)).execute(
        owner_id=user, conversation_id=conversation_id
    )
    if snapshot is None:
        raise NotFoundError("Conversation not found", code="conversation.not_found")
    await db.commit()  # lazy repair 가 쓴 run_status 영속
    return ConversationSnapshotResponse(
        conversation=ConversationResponse.from_entity(snapshot.conversation),
        messages=[MessageResponse.from_entity(m) for m in snapshot.messages],
    )


@router.patch(
    "/{conversation_id}/proposals/{proposal_id}", status_code=status.HTTP_204_NO_CONTENT
)
async def update_proposal_status(
    conversation_id: UUID,
    proposal_id: UUID,
    payload: ProposalStatusUpdateRequest,
    db: DBSession,
    user: CurrentUser,
) -> Response:
    """proposal 카드 확정/취소 영속 — 클라이언트가 확정 실행(REST) **성공 후** 호출한다.

    스냅샷 복귀·히스토리 재진입 시 카드가 pending 으로 되살아나 "안 누른 것처럼" 보이는
    문제(2026-06-10 버그 리포트)의 단일 원천 해결 — 스냅샷의 proposals entry 에 ``status``
    가 실려 내려간다. 실행 자체(PATCH/DELETE/ingest)와 별도 호출인 것은 의도: 실행 경로가
    5종(로컬 알림 포함 — 서버 무관)이라 실행 API 에 끼워 넣을 단일 지점이 없다.
    """
    updated = await SetProposalStatus(repository=make_conversation_repository(db)).execute(
        owner_id=user,
        conversation_id=conversation_id,
        proposal_id=proposal_id,
        status=payload.status,
    )
    if not updated:
        raise NotFoundError("Proposal not found", code="conversation.proposal_not_found")
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/{conversation_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_conversation(conversation_id: UUID, db: DBSession, user: CurrentUser) -> Response:
    """히스토리 스와이프 삭제 — soft delete (행·메시지 보존)."""
    deleted = await DeleteConversation(repository=make_conversation_repository(db)).execute(
        owner_id=user, conversation_id=conversation_id
    )
    if not deleted:
        raise NotFoundError("Conversation not found", code="conversation.not_found")
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
