"""Capture 조회 use case 모음.

다른 모듈(예: agent)이 capture 조회/소유권 검증이 필요할 때 이 application 진입점만 import한다.
infrastructure (`PostgresCaptureRepository`) 직접 reach를 차단해 모듈 경계를 유지한다.
"""

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.captures.domain.entities import Capture
from app.modules.captures.domain.ports import CaptureRepository
from app.modules.captures.infrastructure.repository import PostgresCaptureRepository


def make_capture_repository(session: AsyncSession) -> CaptureRepository:
    """Factory — 라우터/유스케이스 호출자가 infrastructure를 직접 알 필요 없게 한다."""
    return PostgresCaptureRepository(session)


@dataclass(slots=True)
class GetCaptureForOwner:
    repository: CaptureRepository

    async def execute(self, *, owner_id: UUID, capture_id: UUID) -> Capture | None:
        return await self.repository.find_by_id(owner_id=owner_id, capture_id=capture_id)
