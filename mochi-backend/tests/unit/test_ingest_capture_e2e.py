"""IngestCapture use case 도메인-레벨 E2E (in-memory repo).

실제 Postgres E2E 는 `tests/integration` 에서 별도로 다룬다.
여기서는 image_refs 가 명령 → 도메인 → repo 까지 손실 없이 흐르는지 검증한다.
"""

from uuid import uuid4

import pytest

from app.modules.mochi_items.application.ingest_capture import (
    IngestCapture,
    IngestCaptureCommand,
)
from app.modules.mochi_items.domain.entities import (
    Capture,
    CaptureChannel,
    ImageRef,
    LifecycleState,
)


class _InMemoryRepository:
    def __init__(self) -> None:
        self._captures: dict = {}
        self._idem: dict = {}

    async def add(self, *, owner_id, capture: Capture) -> None:
        self._captures[(owner_id, capture.id)] = capture

    async def find_by_id(self, *, owner_id, capture_id):
        return self._captures.get((owner_id, capture_id))

    async def update_lifecycle(self, *, owner_id, capture_id, new_state: LifecycleState) -> None:
        capture = self._captures[(owner_id, capture_id)]
        capture.lifecycle = new_state

    async def list_recent(self, *, owner_id, limit):
        return list(self._captures.values())[:limit]

    async def list_by_intent(self, *, owner_id, intent, limit):
        return [c for c in self._captures.values() if c.intent == intent][:limit]

    async def already_ingested(self, *, owner_id, idempotency_key):
        return self._captures.get((owner_id, self._idem.get((owner_id, idempotency_key))))

    async def remember_idempotency(self, *, owner_id, idempotency_key, capture_id) -> None:
        self._idem[(owner_id, idempotency_key)] = capture_id


class _CollectingNotifier:
    def __init__(self) -> None:
        self.events: list = []

    async def emit(self, *, owner_id, capture_id) -> None:
        self.events.append((owner_id, capture_id))


@pytest.mark.asyncio
async def test_ingest_persists_image_refs_and_emits_event() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = IngestCapture(repository=repo, notifier=notifier)

    owner = uuid4()
    cmd = IngestCaptureCommand(
        owner_id=owner,
        channel=CaptureChannel.SCREENSHOT,
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
    assert len(result.capture.source.image_refs) == 1
    assert result.capture.source.image_refs[0].sha256 == "a" * 64
    assert notifier.events == [(owner, result.capture.id)]


@pytest.mark.asyncio
async def test_idempotent_replay_returns_same_capture() -> None:
    repo = _InMemoryRepository()
    notifier = _CollectingNotifier()
    use_case = IngestCapture(repository=repo, notifier=notifier)

    owner = uuid4()
    cmd = IngestCaptureCommand(
        owner_id=owner,
        channel=CaptureChannel.APP_DIRECT_INPUT,
        url=None,
        text="x",
        user_memo=None,
        idempotency_key="dup",
    )
    first = await use_case.execute(cmd)
    second = await use_case.execute(cmd)
    assert second.was_idempotent_replay is True
    assert second.capture.id == first.capture.id
    assert len(notifier.events) == 1
