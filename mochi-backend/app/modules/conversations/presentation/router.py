"""/conversations 라우터 — 채팅 세션 목록·스냅샷·삭제.

메시지 전송(POST /{id}/messages, POST-as-SSE)은 PR-2 (agent run + queue 중계).
"""

from uuid import UUID

from fastapi import APIRouter, Query, status
from fastapi.responses import Response

from app.core.deps import DBSession
from app.core.error_envelope import NotFoundError
from app.core.security import CurrentUser
from app.modules.conversations.application.queries import (
    DeleteConversation,
    GetConversationSnapshot,
    ListConversations,
    make_conversation_repository,
)
from app.modules.conversations.presentation.schemas import (
    ConversationListResponse,
    ConversationResponse,
    ConversationSnapshotResponse,
    MessageResponse,
)

router = APIRouter(prefix="/conversations", tags=["conversations"])


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
