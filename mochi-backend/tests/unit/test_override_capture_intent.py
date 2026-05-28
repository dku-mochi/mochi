"""OverrideCaptureIntent use case — owner 검증 + primary 교체 흐름."""

from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.application.override_capture_intent import (
    OverrideCaptureIntent,
    OverrideIntentCommand,
)
from app.modules.mochi_items.domain.entities import Capture, CaptureChannel, CaptureSource, LifecycleState
from app.modules.mochi_items.domain.value_objects import (
    IntentClassification,
    IntentClassificationResult,
)
from app.shared.intent import Intent


class _InMemoryRepository:
    def __init__(self) -> None:
        self._captures: dict = {}

    async def add(self, *, owner_id, capture: Capture) -> None:
        self._captures[(owner_id, capture.id)] = capture

    async def find_by_id(self, *, owner_id, capture_id):
        return self._captures.get((owner_id, capture_id))

    async def update_lifecycle(self, *, owner_id, capture_id, new_state: LifecycleState) -> None:
        self._captures[(owner_id, capture_id)].lifecycle = new_state

    async def update_primary_intent(
        self, *, owner_id, capture_id, new_primary, new_secondary
    ) -> None:
        cap = self._captures[(owner_id, capture_id)]
        cap.intent = new_primary
        cap.secondary_intents = new_secondary

    async def list_recent(self, *, owner_id, limit):
        return list(self._captures.values())[:limit]

    async def list_by_intent(self, *, owner_id, intent, limit):
        return [c for c in self._captures.values() if c.intent == intent][:limit]

    async def already_ingested(self, *, owner_id, idempotency_key):
        return None

    async def remember_idempotency(self, *, owner_id, idempotency_key, capture_id) -> None:
        return None


def _seed_capture(repo: _InMemoryRepository, owner_id) -> Capture:
    result = IntentClassificationResult(
        candidates=(
            IntentClassification(label="구매 고민", intent=Intent.TODO, applicability=0.95, reasoning="-"),
            IntentClassification(label="가격 비교", intent=Intent.KNOWLEDGE, applicability=0.75, reasoning="-"),
            IntentClassification(label="위시리스트", intent=Intent.MEMO, applicability=0.40, reasoning="-"),
        )
    )
    cap = Capture.from_classification(
        source=CaptureSource(channel=CaptureChannel.SCREENSHOT),
        classification=result,
    )
    repo._captures[(owner_id, cap.id)] = cap
    return cap


@pytest.mark.asyncio
async def test_override_returns_not_found_when_capture_missing() -> None:
    repo = _InMemoryRepository()
    use_case = OverrideCaptureIntent(repository=repo)
    with pytest.raises(NotFoundError):
        await use_case.execute(
            OverrideIntentCommand(owner_id=uuid4(), capture_id=uuid4(), new_primary=Intent.MEMO)
        )


@pytest.mark.asyncio
async def test_override_returns_not_found_when_owner_mismatch() -> None:
    """다른 사용자의 capture_id 로 PATCH 호출하면 404 — cross-tenant 누설 차단."""
    repo = _InMemoryRepository()
    owner = uuid4()
    cap = _seed_capture(repo, owner)

    use_case = OverrideCaptureIntent(repository=repo)
    with pytest.raises(NotFoundError):
        await use_case.execute(
            OverrideIntentCommand(owner_id=uuid4(), capture_id=cap.id, new_primary=Intent.MEMO)
        )


@pytest.mark.asyncio
async def test_override_swaps_primary_and_moves_old_to_front_of_secondary() -> None:
    repo = _InMemoryRepository()
    owner = uuid4()
    cap = _seed_capture(repo, owner)
    assert cap.intent is Intent.TODO  # 시작은 LLM top-1

    use_case = OverrideCaptureIntent(repository=repo)
    updated = await use_case.execute(
        OverrideIntentCommand(owner_id=owner, capture_id=cap.id, new_primary=Intent.KNOWLEDGE)
    )

    assert updated.intent is Intent.KNOWLEDGE
    assert updated.secondary_intents == (Intent.TODO, Intent.MEMO)
    # applicability 분포는 유지.
    assert updated.intent_applicability[Intent.TODO] == 0.95
