"""BackTapIngest use case 도메인-레벨 E2E (in-memory repo + fake classifier)."""

from uuid import uuid4

import pytest

from app.modules.mochi_items.application.back_tap_ingest import (
    BackTapIngest,
    BackTapIngestCommand,
)
from app.modules.mochi_items.domain.entities import IngestChannel, LifecycleState, MochiItem
from app.modules.mochi_items.domain.value_objects import (
    IntentClassification,
    IntentClassificationResult,
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

    async def update_lifecycle(self, *, owner_id, mochi_item_id, new_state: LifecycleState) -> None:
        self._items[(owner_id, mochi_item_id)].lifecycle = new_state

    async def update_primary_intent(
        self, *, owner_id, mochi_item_id, new_primary, new_secondary
    ) -> None:
        item = self._items[(owner_id, mochi_item_id)]
        item.intent = new_primary
        item.secondary_intents = new_secondary

    async def list_recent(self, *, owner_id, limit):
        return list(self._items.values())[:limit]

    async def list_by_intent(self, *, owner_id, intent, limit):
        return [c for c in self._items.values() if c.intent == intent][:limit]

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


class _FakeClassifier:
    def __init__(self, *triples: tuple[str, Intent, float]) -> None:
        self.call_count = 0
        self._result = IntentClassificationResult(
            candidates=tuple(
                IntentClassification(label=label, intent=intent, applicability=score, reasoning="r")
                for label, intent, score in triples
            )
        )

    async def classify(self, *, image: bytes, mime: str):
        self.call_count += 1
        return self._result


@pytest.mark.asyncio
async def test_classifies_and_persists_primary_secondary_applicability() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    classifier = _FakeClassifier(
        ("구매 고민", Intent.TODO, 0.95),
        ("가격 비교", Intent.KNOWLEDGE, 0.75),
        ("위시리스트", Intent.MEMO, 0.40),
    )
    use_case = BackTapIngest(repository=repo, notifier=notifier, classifier=classifier)

    owner = uuid4()
    cmd = BackTapIngestCommand(
        owner_id=owner,
        idempotency_key="bt-1",
        image=b"PNG-bytes",
        mime_type="image/png",
        byte_size=9,
        sha256="a" * 64,
        user_memo=None,
    )
    result = await use_case.execute(cmd)

    assert not result.was_idempotent_replay
    assert classifier.call_count == 1
    assert result.item.intent is Intent.TODO
    assert result.item.secondary_intents == (Intent.KNOWLEDGE, Intent.MEMO)
    assert result.item.intent_applicability[Intent.TODO] == 0.95
    assert result.item.source.channel is IngestChannel.SCREENSHOT
    assert len(result.item.source.image_refs) == 1
    assert result.item.source.image_refs[0].sha256 == "a" * 64
    assert notifier.events == [(owner, result.item.id)]
    assert len(result.candidates) == 3


@pytest.mark.asyncio
async def test_idempotent_replay_returns_same_item_without_calling_classifier() -> None:
    """같은 Idempotency-Key 로 재요청하면 Gemini 호출 비용·latency 가 다시 발생하지 않는다."""
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    classifier = _FakeClassifier(
        ("회신", Intent.TODO, 0.9),
        ("대화 박제", Intent.MEMO, 0.6),
        ("약속 잡기", Intent.SCHEDULE, 0.4),
    )
    use_case = BackTapIngest(repository=repo, notifier=notifier, classifier=classifier)

    owner = uuid4()
    cmd = BackTapIngestCommand(
        owner_id=owner,
        idempotency_key="dup",
        image=b"x",
        mime_type="image/jpeg",
        byte_size=1,
        sha256="b" * 64,
    )
    first = await use_case.execute(cmd)
    second = await use_case.execute(cmd)

    assert second.was_idempotent_replay is True
    assert second.item.id == first.item.id
    assert classifier.call_count == 1  # 두 번째 요청에선 호출 안 함
    assert len(notifier.events) == 1
    assert second.candidates == ()  # 멱등 replay 시 candidates 는 빈 리스트.
