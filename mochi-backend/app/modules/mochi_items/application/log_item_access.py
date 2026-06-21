from dataclasses import dataclass
from uuid import UUID

from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import AccessSource


@dataclass(slots=True)
class LogItemAccessCommand:
    owner_id: UUID
    mochi_item_id: UUID
    source: AccessSource


class LogItemAccess:
    """상세 열람 이벤트 기록 — best-effort 관찰 로그(능동 회수 랭킹 신호).

    사용자가 상세를 연 직전 화면(``source``)과 시각을 append-only 로 1행 남긴다. 분석결과도
    상태전이도 아니라 순수 관찰이라, 같은 item 다회 열람은 다회 행으로 쌓인다(멱등 아님 — 빈도 신호).

    **best-effort**: 없는/다른 owner item 은 조용히 no-op(404 안 던짐) — 로깅 실패가 상세
    조회/UI 를 막으면 안 된다. iOS 도 호출부에서 실패를 삼켜(``try?``) 이중 격리한다.
    """

    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: LogItemAccessCommand) -> None:
        item = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        if item is None:
            return  # best-effort no-op — 없는/타 owner item 은 조용히 무시
        await self._repo.log_access(
            owner_id=command.owner_id,
            mochi_item_id=command.mochi_item_id,
            source=command.source,
        )
