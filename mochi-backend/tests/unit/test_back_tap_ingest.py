"""BackTapIngest use case 도메인-레벨 검증 (in-memory repo).

worker 단일 분석 경로 전환(2026-05-30) 후: 동기 분류 없이 `.screenshot` MochiItem 을
`.ingested` 로 적재하고 outbox 로 emit 한다. 4-Intent 후보·confidence 는 worker 가 비동기로 채운다.
"""

from uuid import uuid4

import pytest

from app.modules.mochi_items.application.back_tap_ingest import (
    BackTapIngest,
    BackTapIngestCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    LifecycleStateKind,
    MochiItem,
)
from app.shared.intent import Intent


class _InMemoryRepository:
    def __init__(self) -> None:
        self._items: dict = {}
        self._idem: dict = {}

    async def add(self, *, owner_id, item: MochiItem) -> None:
        self._items[(owner_id, item.id)] = item

    async def find_by_id(self, *, owner_id, mochi_item_id):
        return self._items.get((owner_id, mochi_item_id))

    async def already_ingested(self, *, owner_id, idempotency_key):
        mochi_item_id = self._idem.get((owner_id, idempotency_key))
        return self._items.get((owner_id, mochi_item_id)) if mochi_item_id else None

    async def remember_idempotency(self, *, owner_id, idempotency_key, mochi_item_id) -> None:
        self._idem[(owner_id, idempotency_key)] = mochi_item_id


class _CollectingNotifier:
    def __init__(self) -> None:
        self.events: list = []

    async def emit(self, *, owner_id, mochi_item_id) -> None:
        self.events.append((owner_id, mochi_item_id))


def _cmd(owner, key="bt-1", sha="a" * 64) -> BackTapIngestCommand:
    return BackTapIngestCommand(
        owner_id=owner,
        idempotency_key=key,
        object_key="captures/o/a.png",
        mime_type="image/png",
        byte_size=9,
        sha256=sha,
        user_memo=None,
    )


@pytest.mark.asyncio
async def test_ingests_screenshot_as_ingested_and_emits_outbox() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = BackTapIngest(repository=repo, notifier=notifier)

    owner = uuid4()
    result = await use_case.execute(_cmd(owner))

    assert not result.was_idempotent_replay
    # 분류 전 — primary 는 MEMO default, 후보·confidence 는 worker 가 채운다.
    assert result.item.intent is Intent.MEMO
    assert result.item.intent_candidates == ()
    assert result.item.lifecycle.kind is LifecycleStateKind.INGESTED
    assert result.item.source.channel is IngestChannel.SCREENSHOT
    assert len(result.item.source.image_refs) == 1
    assert result.item.source.image_refs[0].sha256 == "a" * 64
    assert notifier.events == [(owner, result.item.id)]


@pytest.mark.asyncio
async def test_idempotent_replay_returns_same_item_without_re_emitting() -> None:
    """같은 Idempotency-Key 로 재요청하면 동일 item 을 반환하고 outbox 를 다시 emit 하지 않는다."""
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = BackTapIngest(repository=repo, notifier=notifier)

    owner = uuid4()
    cmd = _cmd(owner, key="dup", sha="b" * 64)
    first = await use_case.execute(cmd)
    second = await use_case.execute(cmd)

    assert second.was_idempotent_replay is True
    assert second.item.id == first.item.id
    assert len(notifier.events) == 1
