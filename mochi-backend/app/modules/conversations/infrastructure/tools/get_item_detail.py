"""get_item_detail — 기록 1건 풀 컨텐츠 조회 채팅 툴 (read-only).

검색은 스니펫만 주므로, "그거 자세히 요약해줘" 후속 질문과 수정 proposal 작성(PR-3 —
instance_id 가 여기서 나온다)에 풀 컨텐츠가 필요하다. ``mochi_items.application`` 위임
(허용 경계 — application 은 cross-module import 가능).
"""

from collections.abc import Callable
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.domain.ports import ChatToolResult
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)
from app.modules.mochi_items.domain.entities import PlaceInfo, ReferenceLink

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "mochi_item_id": {
            "type": "string",
            "description": "Record UUID — must come from a prior search_items result.",
        },
    },
    "required": ["mochi_item_id"],
}


def _place_dict(place: PlaceInfo) -> dict[str, Any]:
    """PlaceInfo → 값 있는 키만. 상세 지도 섹션이 저장해 둔 좌표·주소·별점을 채팅이 읽는다."""
    return {
        key: value
        for key, value in {
            "name": place.name,
            "lat": place.lat,
            "lng": place.lng,
            "category": place.category,
            "address": place.address,
            "road_address": place.road_address,
            "map_url": place.map_url,
            "rating": place.rating,
            "rating_count": place.rating_count,
            "image_url": place.image_url,
        }.items()
        if value is not None
    }


def _reference_dict(link: ReferenceLink) -> dict[str, Any]:
    """ReferenceLink → 사용자-facing 필드만. 랭킹 내부값(rank_profile/source)은 채팅에 무의미해 제외."""
    return {
        key: value
        for key, value in {
            "url": link.url,
            "title": link.title,
            "label": link.label,
            "role": link.role,
            "provider": link.provider,
            "subtitle": link.subtitle,
            "price_text": link.price_text,
            "usefulness": link.usefulness,
        }.items()
        if value is not None
    }


class GetItemDetailTool:
    name = "get_item_detail"
    label = "기록을 자세히 보고 있어요"
    description = (
        "Read one record in full: text, memo, url, summary, category, importance, whether "
        "it's a favorite, any saved place (coordinates, address, rating, photo) and reference "
        "links, plus its intent instances (with instance ids, reasoning, and payload). Use "
        "after search_items when the snippet is not enough to answer — this is the only way to "
        "reach a record's place, links, and full plan details — or before proposing a change."
    )
    parameters = _PARAMETERS

    def __init__(self, session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        raw_id = args.get("mochi_item_id")
        try:
            mochi_item_id = UUID(str(raw_id))
        except (ValueError, TypeError):
            return ChatToolResult(
                payload={"error": "invalid mochi_item_id — use a UUID from search_items results"},
                summary="기록을 찾지 못했어요",
            )

        async with self._session_factory() as session:
            item = await GetMochiItemForOwner(repository=make_mochi_item_repository(session)).execute(
                owner_id=owner_id, mochi_item_id=mochi_item_id
            )

        if item is None:
            return ChatToolResult(
                payload={"error": "record not found"},
                summary="기록을 찾지 못했어요",
            )

        instances = [
            {
                "instance_id": str(instance.id),
                "intent_type": instance.intent_type.value,
                "label": instance.label,
                "lifecycle": instance.lifecycle.kind.value,
                "archive_reason": (
                    instance.lifecycle.archive_reason.value if instance.lifecycle.archive_reason else None
                ),
                "reasoning": instance.reasoning or None,
                "payload": {
                    key: value
                    for key, value in {
                        "title": instance.payload.title,
                        "date": instance.payload.date,
                        "time": instance.payload.time,
                        "end_date": instance.payload.end_date,
                        "end_time": instance.payload.end_time,
                        "deadline": instance.payload.deadline,
                        "person": instance.payload.person,
                        "topic": instance.payload.topic,
                        "url": instance.payload.url,
                        "note": instance.payload.note,
                    }.items()
                    if value is not None
                },
            }
            for instance in item.intent_instances
        ]
        payload: dict[str, Any] = {
            "id": str(item.id),
            "channel": item.source.channel.value,
            "url": item.source.url,
            "text": item.source.text,
            "user_memo": item.source.user_memo,
            "summary": item.summary,
            "category": item.category,
            "importance": item.importance,
            "is_favorite": item.is_favorite,
            "captured_at": item.source.captured_at.isoformat(),
            "instances": instances,
        }
        # entities 유래 항목은 값이 있을 때만 싣는다 — 없는 키를 None 으로 채우지 않는다(토큰·오독 방지).
        if item.place is not None:
            payload["place"] = _place_dict(item.place)
        if item.reference_links:
            payload["reference_links"] = [_reference_dict(link) for link in item.reference_links]
        if item.shopping_product_query:
            payload["shopping_product_query"] = item.shopping_product_query
        # 이미지 본문은 view_item_image 가 준다 — 여기선 "볼 이미지가 있다"만 알려 그 호출을 유도한다.
        if any(image.object_key for image in item.source.image_refs):
            payload["has_images"] = True
        return ChatToolResult(
            payload=payload,
            summary="기록을 자세히 읽었어요",
            compact={"id": str(item.id), "summary": (item.summary or "")[:60]},
        )
