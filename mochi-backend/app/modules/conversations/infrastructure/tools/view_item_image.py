"""view_item_image — 기록의 업로드된 캡처 이미지를 모델 컨텍스트에 첨부하는 채팅 툴 (read-only).

사전 추출(요약·intent payload)은 캡처의 lossy projection 이라, 답이 "캡처에 실제로 뭐가
보이는가"에 달린 질문은 텍스트 필드로 받아칠 수 없다. 이 툴은 item 의 GCS object key 를
``gs://`` URI 로 해석해 ``ChatToolResult.images`` 로 돌려주고, 실제 첨부는 run 루프가 별도
user part 로 주입한다 — 분석 경로(``mochi_item_gateway``)와 동일하게 Vertex 가 직접 read,
백엔드는 bytes 무접촉. 데이터 경계는 분석 시점과 동일하다 (PRIVACY §10).

이미지는 현재 턴 in-memory 전용 — 과거 턴 히스토리엔 ``compact`` 만 남아 재주입되지
않는다(토큰 비용). compact note 가 모델에게 "다시 보려면 재호출" 경로를 알려준다.
"""

from typing import Any
from uuid import UUID

from app.modules.conversations.domain.ports import ChatToolResult
from app.modules.conversations.infrastructure.tools.propose import ItemReader

#: 툴 결과당 첨부 상한 — 요청 크기·비용(flash-lite 비용 최우선)·latency 의 유계 보장.
#: 캡처 item 은 보통 1장이라 실사용에선 닿지 않는다. 초과분은 payload 로 모델에 알린다.
_MAX_IMAGES = 3

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "mochi_item_id": {
            "type": "string",
            "description": "Record UUID — must come from a prior search_items or get_item_detail result.",
        },
    },
    "required": ["mochi_item_id"],
}


class ViewItemImageTool:
    name = "view_item_image"
    label = "캡처 이미지를 보고 있어요"
    description = (
        "Attach the record's captured image(s) to the conversation so you can read the visual "
        "detail directly. The stored text and summary are a lossy projection of the capture — "
        "use this when the answer hinges on what the capture actually shows (a number on screen, "
        "layout, small print, anything the text fields don't carry). Images from earlier turns "
        "are no longer visible; call again instead of recalling."
    )
    parameters = _PARAMETERS

    def __init__(self, item_reader: ItemReader, *, bucket: str):
        self._read = item_reader
        self._bucket = bucket

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        try:
            mochi_item_id = UUID(str(args.get("mochi_item_id")))
        except (ValueError, TypeError):
            return ChatToolResult(
                payload={"error": "invalid mochi_item_id — use a UUID from search_items results"},
                summary="기록을 찾지 못했어요",
            )

        item = await self._read(owner_id, mochi_item_id)
        if item is None:
            return ChatToolResult(
                payload={"error": "record not found"},
                summary="기록을 찾지 못했어요",
            )

        images = tuple(
            (f"gs://{self._bucket}/{ref.object_key}", ref.mime_type)
            for ref in item.source.image_refs
            if ref.object_key
        )
        if not images:
            return ChatToolResult(
                payload={"error": "this record has no captured image — answer from its text fields"},
                summary="이 기록엔 이미지가 없어요",
            )

        attached = images[:_MAX_IMAGES]
        payload: dict[str, Any] = {
            "id": str(item.id),
            "image_count": len(attached),
            "attached": True,
        }
        if len(images) > _MAX_IMAGES:
            payload["omitted_image_count"] = len(images) - _MAX_IMAGES
        return ChatToolResult(
            payload=payload,
            summary="캡처 이미지를 봤어요",
            compact={
                "id": str(item.id),
                "note": (
                    "images were attached in an earlier turn and are no longer visible — "
                    "call view_item_image again if visual detail is needed"
                ),
            },
            images=attached,
        )
