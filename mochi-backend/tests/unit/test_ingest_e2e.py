"""Ingest use case 도메인-레벨 E2E (in-memory repo).

실제 Postgres E2E 는 `tests/integration` 에서 별도로 다룬다.
여기서는 image_refs 가 명령 → 도메인 → repo 까지 손실 없이 흐르는지 검증한다.
"""

from uuid import uuid4

import pytest

from app.modules.mochi_items.application.ingest import (
    Ingest,
    IngestCommand,
)
from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import IntentInstance
from app.shared.intent import Intent


class _InMemoryRepository:
    def __init__(self) -> None:
        self._items: dict = {}
        self._idem: dict = {}

    async def add(self, *, owner_id, item: MochiItem) -> None:
        self._items[(owner_id, item.id)] = item

    async def find_by_id(self, *, owner_id, mochi_item_id):
        return self._items.get((owner_id, mochi_item_id))

    async def list_recent(self, *, owner_id, limit):
        return list(self._items.values())[:limit]

    async def list_by_intent(self, *, owner_id, intent, limit):
        return [c for c in self._items.values() if intent in c.intent_types][:limit]

    async def already_ingested(self, *, owner_id, idempotency_key):
        return self._items.get((owner_id, self._idem.get((owner_id, idempotency_key))))

    async def remember_idempotency(self, *, owner_id, idempotency_key, mochi_item_id) -> None:
        self._idem[(owner_id, idempotency_key)] = mochi_item_id


class _CollectingNotifier:
    def __init__(self) -> None:
        self.events: list = []

    async def emit(self, *, owner_id, mochi_item_id) -> None:
        self.events.append((owner_id, mochi_item_id))


@pytest.mark.asyncio
async def test_ingest_persists_image_refs_and_emits_event() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = Ingest(repository=repo, notifier=notifier)

    owner = uuid4()
    cmd = IngestCommand(
        owner_id=owner,
        channel=IngestChannel.SCREENSHOT,
        url=None,
        text="hello world",
        user_memo="quick note",
        idempotency_key="abc-123",
        image_refs=(
            ImageRef(
                sha256="a" * 64,
                mime_type="image/heic",
                byte_size=12345,
                object_key=None,
            ),
        ),
    )

    result = await use_case.execute(cmd)
    assert not result.was_idempotent_replay
    assert len(result.item.source.image_refs) == 1
    assert result.item.source.image_refs[0].sha256 == "a" * 64
    assert notifier.events == [(owner, result.item.id)]


@pytest.mark.asyncio
async def test_ingest_preserves_analysis_ocr_text() -> None:
    # ephemeral OCR 이 command → 도메인 source 까지 손실 없이 흐른다 (worker 분석이 읽고 추론 후 삭제).
    repo = _InMemoryRepository()
    use_case = Ingest(repository=repo, notifier=_CollectingNotifier())
    cmd = IngestCommand(
        owner_id=uuid4(),
        channel=IngestChannel.SCREENSHOT,
        url=None,
        text=None,
        user_memo=None,
        analysis_ocr_text="화면 OCR transcript",
        idempotency_key="ocr-1",
    )
    result = await use_case.execute(cmd)
    assert result.item.source.analysis_ocr_text == "화면 OCR transcript"


@pytest.mark.asyncio
async def test_confirmed_instances_path_drops_ephemeral_ocr() -> None:
    # confirmed_instances 경로는 즉시 lifecycle=analyzed 라 outbox·삭제 훅을 안 거친다. ephemeral OCR 이
    # 동시 전송돼도 persist-without-delete 영구 잔류를 막으려 use case 가 비운다(불변식 코드 강제, 리뷰 P1).
    repo = _InMemoryRepository()
    use_case = Ingest(repository=repo, notifier=_CollectingNotifier())
    cmd = IngestCommand(
        owner_id=uuid4(),
        channel=IngestChannel.CHAT,
        url=None,
        text="채팅 확정 일정",
        user_memo=None,
        analysis_ocr_text="leaked card 1234-5678",  # 입력 계약상 막혀있지 않으니 방어적으로 검증
        idempotency_key="confirmed-ocr",
        confirmed_instances=(IntentInstance(intent_type=Intent.SCHEDULE),),
    )
    result = await use_case.execute(cmd)
    assert result.item.source.analysis_ocr_text is None


@pytest.mark.asyncio
async def test_idempotent_replay_returns_same_item() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = Ingest(repository=repo, notifier=notifier)

    owner = uuid4()
    cmd = IngestCommand(
        owner_id=owner,
        channel=IngestChannel.APP_DIRECT_INPUT,
        url=None,
        text="x",
        user_memo=None,
        idempotency_key="dup",
    )
    first = await use_case.execute(cmd)
    second = await use_case.execute(cmd)
    assert second.was_idempotent_replay is True
    assert second.item.id == first.item.id
    assert len(notifier.events) == 1
