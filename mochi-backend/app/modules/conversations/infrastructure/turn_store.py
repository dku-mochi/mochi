"""``ChatTurnStore`` 구현 — detached run task 의 단계별 영속.

request 세션을 쓸 수 없는 detached task 가 **연산마다 자체 세션을 열고 즉시 commit** 한다 —
클라이언트 이탈·서버 죽음 어느 시점에도 직전 단계까지는 DB 에 남는다(스냅샷 재조회의 전제).
"""

from uuid import UUID

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.domain.entities import Message, RunStatus
from app.modules.conversations.domain.ports import ChatTurnStore, ResolvedCitation
from app.modules.conversations.infrastructure.repository import PostgresConversationRepository

#: 컨텍스트 윈도우 — 최근 N messages (세션 자동분리 설계라 초과가 드묾, 요약 압축 생략).
HISTORY_MESSAGES = 20


class SessionChatTurnStore(ChatTurnStore):
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def load_history(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        async with self._session_factory() as session:
            messages = await PostgresConversationRepository(session).list_messages(
                owner_id=owner_id, conversation_id=conversation_id
            )
        return messages[-HISTORY_MESSAGES:]

    async def append(self, *, owner_id: UUID, message: Message) -> bool:
        async with self._session_factory() as session:
            added = await PostgresConversationRepository(session).add_message(
                owner_id=owner_id, message=message
            )
            await session.commit()
        return added

    async def set_run_status(self, *, owner_id: UUID, run_id: UUID, status: RunStatus) -> bool:
        async with self._session_factory() as session:
            updated = await PostgresConversationRepository(session).set_run_status(
                owner_id=owner_id, run_id=run_id, status=status
            )
            await session.commit()
        return updated

    async def resolve_citations(
        self, *, owner_id: UUID, mochi_item_ids: list[UUID]
    ) -> list[ResolvedCitation]:
        if not mochi_item_ids:
            return []
        # 타 모듈 ORM(infrastructure) import 는 경계 위반 — raw SQL 로 조회 (search_items 와 동일 접근).
        sql = text(
            """
            SELECT id, summary, text
            FROM mochi_items
            WHERE id = ANY(:ids) AND owner_id = :owner_id AND deleted_at IS NULL
            """
        ).bindparams(
            bindparam("ids", list(mochi_item_ids)),
            bindparam("owner_id", owner_id),
        )
        async with self._session_factory() as session:
            rows = (await session.execute(sql)).all()
        by_id = {row.id: row for row in rows}
        resolved: list[ResolvedCitation] = []
        for mochi_item_id in mochi_item_ids:
            row = by_id.get(mochi_item_id)
            if row is None:
                continue  # 미실재·타인 소유 — citation 미생성 (마커 본문은 보존)
            source = row.summary or row.text or ""
            resolved.append(
                ResolvedCitation(
                    mochi_item_id=mochi_item_id,
                    title=(row.summary or row.text or "")[:80] or None,
                    snippet=source[:200] or None,
                )
            )
        return resolved
