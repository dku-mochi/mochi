from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository


@dataclass(slots=True)
class SetFavoriteCommand:
    owner_id: UUID
    mochi_item_id: UUID
    is_favorite: bool


class SetFavorite:
    """즐겨찾기 신호 set-state 유스케이스 — 사용자가 검색 카드·상세에서 토글한다.

    즐겨찾기는 분석결과가 아니라 "사용자가 모찌에게 준 중요 신호"다(PRODUCT §1.5 — 모찌가 능동
    회수에 활용). 완료 토글과 같은 set-state 의미라, 같은 값 재전송(응답 유실 재시도·빠른 더블탭)은
    409 가 아니라 no-op(멱등) — iOS 낙관적 업데이트가 오롤백되지 않게.
    """

    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: SetFavoriteCommand) -> MochiItem:
        item = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        if item is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
        if item.is_favorite == command.is_favorite:
            return item  # 멱등 no-op
        updated = await self._repo.set_favorite(
            owner_id=command.owner_id,
            mochi_item_id=command.mochi_item_id,
            is_favorite=command.is_favorite,
        )
        if not updated:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
        refreshed = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        assert refreshed is not None  # 방금 UPDATE 성공 → 반드시 존재
        return refreshed
