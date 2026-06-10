"""conversations 조회·삭제 use case 단위 테스트.

DB 통합 fixture 가 없어(기존 컨벤션) repository 는 in-memory 스텁으로 대체하고,
application 레이어의 스냅샷 조립·stale run lazy repair·404 분기만 검증한다.
owner_id 격리(SQL where)는 PostgresConversationRepository 코드 리뷰가 담당.
"""

from datetime import datetime, timedelta
from uuid import UUID, uuid4

from app.modules.conversations.application.queries import (
    DeleteConversation,
    GetConversationSnapshot,
    ListConversations,
)
from app.modules.conversations.domain.entities import (
    STALE_RUN_SECONDS,
    Conversation,
    Message,
    MessageRole,
    RunStatus,
    title_from_first_message,
)

_OWNER = uuid4()


class _StubRepo:
    """포트 시그니처를 그대로 따르는 in-memory 스텁 (호출 기록 포함)."""

    def __init__(self, conversations: list[Conversation] | None = None) -> None:
        self.conversations = {c.id: c for c in (conversations or [])}
        self.messages: dict[UUID, list[Message]] = {}
        self.stale_calls: list[datetime] = []
        self.deleted: list[UUID] = []

    async def create(self, *, owner_id: UUID, conversation: Conversation) -> None:
        self.conversations[conversation.id] = conversation

    async def find_by_id(self, *, owner_id: UUID, conversation_id: UUID) -> Conversation | None:
        return self.conversations.get(conversation_id)

    async def list_for_owner(self, *, owner_id: UUID, limit: int) -> list[Conversation]:
        ordered = sorted(self.conversations.values(), key=lambda c: c.updated_at, reverse=True)
        return ordered[:limit]

    async def soft_delete(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        if conversation_id not in self.conversations:
            return False
        self.deleted.append(conversation_id)
        del self.conversations[conversation_id]
        return True

    async def add_message(self, *, owner_id: UUID, message: Message) -> bool:
        if message.conversation_id not in self.conversations:
            return False
        self.messages.setdefault(message.conversation_id, []).append(message)
        return True

    async def list_messages(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        rows = self.messages.get(conversation_id, [])
        repaired = []
        for m in rows:
            if (
                m.run_status is RunStatus.RUNNING
                and m.run_started_at is not None
                and self.stale_calls
                and m.run_started_at < self.stale_calls[-1]
            ):
                m.run_status = RunStatus.FAILED
            repaired.append(m)
        return sorted(repaired, key=lambda m: m.created_at)

    async def mark_stale_runs_failed(
        self, *, owner_id: UUID, conversation_id: UUID, started_before: datetime
    ) -> int:
        self.stale_calls.append(started_before)
        return 0


def _conversation(updated_at: datetime | None = None) -> Conversation:
    now = updated_at or datetime.utcnow()
    return Conversation(id=uuid4(), title="t", created_at=now, updated_at=now)


def _user_message(
    conversation_id: UUID,
    *,
    run_status: RunStatus | None = None,
    run_started_at: datetime | None = None,
    created_at: datetime | None = None,
) -> Message:
    return Message(
        id=uuid4(),
        conversation_id=conversation_id,
        role=MessageRole.USER,
        content="질문",
        run_id=uuid4() if run_status else None,
        run_status=run_status,
        run_started_at=run_started_at,
        created_at=created_at or datetime.utcnow(),
    )


# ---------- title_from_first_message ----------


def test_title_keeps_short_first_line() -> None:
    assert title_from_first_message("오늘 데이트 어디서 할까?") == "오늘 데이트 어디서 할까?"


def test_title_truncates_to_40_chars_with_ellipsis() -> None:
    long_text = "가" * 80
    title = title_from_first_message(long_text)
    assert len(title) == 40
    assert title.endswith("…")


def test_title_uses_first_line_only_and_strips() -> None:
    assert title_from_first_message("  첫 줄\n둘째 줄  ") == "첫 줄"


# ---------- GetConversationSnapshot ----------


async def test_snapshot_returns_none_for_missing_conversation() -> None:
    use_case = GetConversationSnapshot(repository=_StubRepo())
    assert await use_case.execute(owner_id=_OWNER, conversation_id=uuid4()) is None


async def test_snapshot_repairs_stale_running_run() -> None:
    conversation = _conversation()
    repo = _StubRepo([conversation])
    stale = _user_message(
        conversation.id,
        run_status=RunStatus.RUNNING,
        run_started_at=datetime.utcnow() - timedelta(seconds=STALE_RUN_SECONDS * 4),
    )
    await repo.add_message(owner_id=_OWNER, message=stale)

    snapshot = await GetConversationSnapshot(repository=repo).execute(
        owner_id=_OWNER, conversation_id=conversation.id
    )

    assert snapshot is not None
    # repair cutoff = now - STALE_RUN_SECONDS (±수 초 허용)
    assert len(repo.stale_calls) == 1
    expected_cutoff = datetime.utcnow() - timedelta(seconds=STALE_RUN_SECONDS)
    assert abs((repo.stale_calls[0] - expected_cutoff).total_seconds()) < 5
    assert snapshot.messages[0].run_status is RunStatus.FAILED


async def test_snapshot_keeps_fresh_running_run() -> None:
    conversation = _conversation()
    repo = _StubRepo([conversation])
    fresh = _user_message(
        conversation.id,
        run_status=RunStatus.RUNNING,
        run_started_at=datetime.utcnow(),
    )
    await repo.add_message(owner_id=_OWNER, message=fresh)

    snapshot = await GetConversationSnapshot(repository=repo).execute(
        owner_id=_OWNER, conversation_id=conversation.id
    )

    assert snapshot is not None
    assert snapshot.messages[0].run_status is RunStatus.RUNNING


async def test_snapshot_orders_messages_by_created_at() -> None:
    conversation = _conversation()
    repo = _StubRepo([conversation])
    now = datetime.utcnow()
    later = _user_message(conversation.id, created_at=now + timedelta(seconds=10))
    earlier = _user_message(conversation.id, created_at=now)
    await repo.add_message(owner_id=_OWNER, message=later)
    await repo.add_message(owner_id=_OWNER, message=earlier)

    snapshot = await GetConversationSnapshot(repository=repo).execute(
        owner_id=_OWNER, conversation_id=conversation.id
    )

    assert snapshot is not None
    assert [m.id for m in snapshot.messages] == [earlier.id, later.id]


# ---------- ListConversations / DeleteConversation ----------


async def test_list_orders_by_updated_at_desc_and_limits() -> None:
    now = datetime.utcnow()
    old = _conversation(updated_at=now - timedelta(hours=2))
    recent = _conversation(updated_at=now)
    repo = _StubRepo([old, recent])

    result = await ListConversations(repository=repo).execute(owner_id=_OWNER, limit=1)

    assert [c.id for c in result] == [recent.id]


async def test_delete_returns_false_for_missing_conversation() -> None:
    assert (
        await DeleteConversation(repository=_StubRepo()).execute(
            owner_id=_OWNER, conversation_id=uuid4()
        )
        is False
    )


async def test_delete_soft_deletes_existing_conversation() -> None:
    conversation = _conversation()
    repo = _StubRepo([conversation])

    assert (
        await DeleteConversation(repository=repo).execute(
            owner_id=_OWNER, conversation_id=conversation.id
        )
        is True
    )
    assert repo.deleted == [conversation.id]


# ---------- proposal 카드 확정/취소 영속 (jsonb 병합 — 순수 함수) ----------


def test_merge_proposal_status_updates_matching_entry_only() -> None:
    from app.modules.conversations.infrastructure.repository import merge_proposal_status

    proposals = [
        {"id": "aaa", "type": "create_memo", "payload": {"text": "x"}},
        {"id": "bbb", "type": "item_delete", "payload": {}},
    ]

    updated = merge_proposal_status(proposals, "bbb", "confirmed")

    assert updated is not None
    assert updated[1]["status"] == "confirmed"
    assert updated[1]["payload"] == {}          # 기존 필드 보존 (병합이지 교체 아님)
    assert "status" not in updated[0]           # 다른 entry 불변
    assert "status" not in proposals[1]         # 원본 리스트 불변 (새 리스트 반환)


def test_merge_proposal_status_returns_none_when_missing() -> None:
    from app.modules.conversations.infrastructure.repository import merge_proposal_status

    assert merge_proposal_status([{"id": "aaa"}], "zzz", "confirmed") is None
    assert merge_proposal_status([], "aaa", "cancelled") is None
