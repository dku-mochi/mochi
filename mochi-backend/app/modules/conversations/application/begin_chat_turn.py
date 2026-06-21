"""메시지 전송의 동기 구간 — 대화 암묵 생성 + 동시 run 차단 + user 행 영속.

여기까지가 request 트랜잭션(router 가 commit), 이후 run 은 detached task (``RunChatTurn``).
conversationID 는 클라이언트가 생성한다 — 첫 메시지가 대화를 암묵 생성(라운드트립 절약,
journal 2026-06-10).
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy.exc import IntegrityError

from app.core.config import get_settings
from app.modules.conversations.domain.entities import (
    Conversation,
    Message,
    MessageRole,
    RunStatus,
    stale_threshold_seconds,
    title_from_first_message,
)
from app.modules.conversations.domain.ports import ConversationRepository


class RunInProgressError(Exception):
    """동일 대화에 진행 중 run 존재 — presentation 이 409 로 변환."""


@dataclass(frozen=True, slots=True)
class BeginChatTurn:
    repository: ConversationRepository

    async def execute(self, *, owner_id: UUID, conversation_id: UUID, text: str) -> Message:
        conversation = await self.repository.find_by_id(owner_id=owner_id, conversation_id=conversation_id)
        if conversation is None:
            try:
                await self.repository.create(
                    owner_id=owner_id,
                    conversation=Conversation(id=conversation_id, title=title_from_first_message(text)),
                )
            except IntegrityError as exc:
                # 동시 첫 메시지 2건 — 둘째의 PK 충돌은 "이미 생성됨"이고, 그 대화엔
                # 상대 run 이 돌고 있으므로 409 로 수렴시킨다.
                raise RunInProgressError from exc
        # stale 정리 후 동시 run 검사 — 서버 재시작으로 남은 유령 running 이 409 를 내지 않게.
        # 임계값은 run 타임아웃(.env 가변)에 마진을 더해 파생 — 살아있는 run 오판 방지.
        await self.repository.mark_stale_runs_failed(
            owner_id=owner_id,
            conversation_id=conversation_id,
            started_before=datetime.utcnow()
            - timedelta(seconds=stale_threshold_seconds(get_settings().chat_run_timeout_seconds)),
        )
        if await self.repository.has_running_run(owner_id=owner_id, conversation_id=conversation_id):
            raise RunInProgressError

        user_message = Message(
            id=uuid4(),
            conversation_id=conversation_id,
            role=MessageRole.USER,
            content=text,
            run_id=uuid4(),
            run_status=RunStatus.RUNNING,
            run_started_at=datetime.utcnow(),
        )
        try:
            await self.repository.add_message(owner_id=owner_id, message=user_message)
        except IntegrityError as exc:
            # has_running_run 의 TOCTOU 잔여 레이스 — 0017 partial unique index
            # (대화당 running 1행)가 DB 에서 흡수, 여기서 409 로 변환.
            raise RunInProgressError from exc
        return user_message
