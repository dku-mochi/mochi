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


class GetItemDetailTool:
    name = "get_item_detail"
    label = "기록을 자세히 보고 있어요"
    description = (
        "Read one record in full: text, memo, url, summary, and its intent instances "
        "(with instance ids and payload). Use after search_items when the snippet is not "
        "enough to answer, or before proposing a change to the record."
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
            item = await GetMochiItemForOwner(
                repository=make_mochi_item_repository(session)
            ).execute(owner_id=owner_id, mochi_item_id=mochi_item_id)

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
        return ChatToolResult(
            payload={
                "id": str(item.id),
                "channel": item.source.channel.value,
                "url": item.source.url,
                "text": item.source.text,
                "user_memo": item.source.user_memo,
                "summary": item.summary,
                "captured_at": item.source.captured_at.isoformat(),
                "instances": instances,
            },
            summary="기록을 자세히 읽었어요",
            compact={"id": str(item.id), "summary": (item.summary or "")[:60]},
        )
