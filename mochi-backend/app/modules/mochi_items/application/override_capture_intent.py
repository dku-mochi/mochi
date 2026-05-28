"""사용자가 알림에서 다른 의도를 골랐을 때 capture 의 primary intent 를 교체한다.

흐름:
1. ``find_by_id`` 로 owner-scoped 조회 (cross-tenant 차단).
2. ``Capture.swap_primary`` — 이전 primary 가 secondary 의 맨 앞으로 이동.
3. ``update_primary_intent`` 로 row 반영. applicability 분포는 유지 (LLM 원 분포 보존).

PATCH 의 본질이 idempotent 라 idempotency key 는 필요하지 않다.
"""

from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import Capture
from app.modules.mochi_items.domain.ports import CaptureRepository
from app.shared.intent import Intent


@dataclass(slots=True)
class OverrideIntentCommand:
    owner_id: UUID
    capture_id: UUID
    new_primary: Intent


class OverrideCaptureIntent:
    def __init__(self, repository: CaptureRepository):
        self._repo = repository

    async def execute(self, command: OverrideIntentCommand) -> Capture:
        capture = await self._repo.find_by_id(
            owner_id=command.owner_id,
            capture_id=command.capture_id,
        )
        if capture is None:
            raise NotFoundError("Capture not found", code="capture.not_found")

        capture.swap_primary(command.new_primary)
        await self._repo.update_primary_intent(
            owner_id=command.owner_id,
            capture_id=capture.id,
            new_primary=capture.intent,
            new_secondary=capture.secondary_intents,
        )
        return capture
