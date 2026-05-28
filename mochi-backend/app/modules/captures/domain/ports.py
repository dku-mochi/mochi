from typing import Protocol
from uuid import UUID

from app.modules.captures.domain.entities import Capture, LifecycleState
from app.modules.captures.domain.value_objects import IntentClassificationResult
from app.shared.intent import Intent


class CaptureRepository(Protocol):
    """Hexagonal outbound port — application layer가 의존하는 추상 저장소.

    모든 read/write 메서드는 ``owner_id`` 를 강제로 받아 cross-tenant 누설을 방지한다.
    """

    async def add(self, *, owner_id: UUID, capture: Capture) -> None: ...
    async def find_by_id(self, *, owner_id: UUID, capture_id: UUID) -> Capture | None: ...
    async def update_lifecycle(
        self,
        *,
        owner_id: UUID,
        capture_id: UUID,
        new_state: LifecycleState,
    ) -> None: ...
    async def update_primary_intent(
        self,
        *,
        owner_id: UUID,
        capture_id: UUID,
        new_primary: Intent,
        new_secondary: tuple[Intent, ...],
    ) -> None: ...
    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[Capture]: ...
    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[Capture]: ...
    async def already_ingested(self, *, owner_id: UUID, idempotency_key: str) -> Capture | None: ...
    async def remember_idempotency(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        capture_id: UUID,
    ) -> None: ...


class CaptureCreatedNotifier(Protocol):
    """Capture 생성 후 비동기 워커가 듣는 outbound port — 이벤트 디스패치."""

    async def emit(self, *, owner_id: UUID, capture_id: UUID) -> None: ...


class IntentClassifier(Protocol):
    """백탭 캡쳐 이미지를 받아 LLM 으로 의도 후보를 도출하는 outbound port.

    구현체는 ``image`` (bytes) 와 ``mime`` (image/jpeg | image/png) 만 입력으로 받고,
    후보 3개를 담은 ``IntentClassificationResult`` 를 반환한다. 어떤 모델·프롬프트·
    timeout 을 쓰는지는 adapter 가 캡슐화한다.
    """

    async def classify(self, *, image: bytes, mime: str) -> IntentClassificationResult: ...
