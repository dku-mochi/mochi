"""propose_* 채팅 툴 5종 — 확인 카드 제안. **어떤 것도 DB 에 쓰지 않는다.**

LLM 루프는 read-only(journal 2026-06-10) — 이 툴들은 대상 실재·전이 합법성을 *지금* 검증해
proposal payload 를 반환할 뿐이고, 실행은 사용자 확정 탭 → REST 가 한다:

| type            | 확정 시 실행 경로 |
|-----------------|------------------|
| item_update     | ``PATCH /mochi_items/{id}`` (콘텐츠 + instance 변경, 한 트랜잭션) |
| item_delete     | ``DELETE /mochi_items/{id}`` |
| create_schedule | ``POST /mochi_items`` + ``confirmedInstances`` (분석 생략 — §5.2 예외) |
| create_memo     | ``POST /mochi_items`` 일반 ingestion (자유 텍스트 — 분석 경유) |
| reminder        | 백엔드 없음 — iOS ``UNUserNotificationCenter`` 로컬 알림 |

검증 실패(미실재·불법 전이)는 proposal 을 만들지 않고 에러 payload 로 모델에 돌려준다 —
사용자에게 깨질 카드를 보여주느니 모델이 정정하는 게 낫다. 확정 시점의 재검증(404 → 카드
만료)은 REST 쪽 책임이다 (reanalyze delete-reinsert known-drift).
"""

from collections.abc import Awaitable, Callable
from contextlib import suppress
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.domain.ports import ChatToolResult
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
)

_KST = ZoneInfo("Asia/Seoul")

#: owner-scoped item 조회 — prod 은 세션 기반, 테스트는 fake 주입.
ItemReader = Callable[[UUID, UUID], Awaitable[MochiItem | None]]


def make_item_reader(
    session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession],
) -> ItemReader:
    async def _read(owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        from app.modules.mochi_items.application.queries import (
            GetMochiItemForOwner,
            make_mochi_item_repository,
        )

        async with session_factory() as session:
            return await GetMochiItemForOwner(repository=make_mochi_item_repository(session)).execute(
                owner_id=owner_id, mochi_item_id=mochi_item_id
            )

    return _read


def _error(message: str) -> ChatToolResult:
    return ChatToolResult(payload={"error": message}, summary="")


def _card(kind: str, payload: dict[str, Any], summary: str) -> ChatToolResult:
    proposal = {"id": str(uuid4()), "type": kind, "payload": payload}
    return ChatToolResult(
        # 모델에게도 proposal 내용을 돌려줘 "카드를 준비했어요" 류 답변의 근거가 되게 한다.
        payload={"proposed": True, "type": kind, **payload},
        summary=summary,
        compact={"type": kind},
        proposal=proposal,
    )


_PAYLOAD_FIELD_PROPS: dict[str, Any] = {
    key: {"type": "string"}
    for key in ("title", "date", "time", "end_date", "end_time", "deadline", "person", "topic", "url", "note")
}
_PAYLOAD_FIELD_PROPS["date"] = {"type": "string", "description": "ISO date, e.g. 2026-06-17"}
_PAYLOAD_FIELD_PROPS["time"] = {"type": "string", "description": "HH:MM"}
_PAYLOAD_FIELD_PROPS["end_date"] = {
    "type": "string",
    "description": "ISO date the event ends, for multi-day events only (date is the start)",
}
_PAYLOAD_FIELD_PROPS["end_time"] = {"type": "string", "description": "HH:MM the event ends"}
_PAYLOAD_FIELD_PROPS["deadline"] = {"type": "string", "description": "ISO date, e.g. 2026-06-17"}

_DISPLAY_PROPS: dict[str, Any] = {
    "type": "object",
    "description": "Card copy the user sees. title: what will happen; description: one line of how.",
    "properties": {"title": {"type": "string"}, "description": {"type": "string"}},
    "required": ["title"],
}


def _display(args: dict[str, Any], fallback_title: str) -> dict[str, Any]:
    display = args.get("display") if isinstance(args.get("display"), dict) else {}
    return {
        "title": (display or {}).get("title") or fallback_title,
        "description": (display or {}).get("description"),
    }


class ProposeItemUpdateTool:
    name = "propose_item_update"
    label = "수정 카드를 준비하고 있어요"
    description = (
        "Propose changes to an existing record — content fields (text/user_memo/summary) and/or "
        "its intent instances (payload fields, label, lifecycle transition like completing a todo). "
        "A fact that an instance payload field represents must change through instance_changes — "
        "rewriting it only into text leaves the structured field stale for everything that reads it. "
        "Use ids from get_item_detail. The user confirms on a card; nothing changes until then."
    )
    parameters: dict[str, Any] = {
        "type": "object",
        "properties": {
            "mochi_item_id": {"type": "string"},
            "changes": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "user_memo": {"type": "string"},
                    "summary": {"type": "string"},
                },
            },
            "instance_changes": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "instance_id": {"type": "string"},
                        "payload": {"type": "object", "properties": _PAYLOAD_FIELD_PROPS},
                        "label": {"type": "string"},
                        "lifecycle": {
                            "type": "object",
                            "properties": {
                                "to": {
                                    "type": "string",
                                    "enum": [k.value for k in InstanceLifecycleKind],
                                },
                                "archive_reason": {
                                    "type": "string",
                                    "enum": [r.value for r in ArchiveReason],
                                },
                            },
                            "required": ["to"],
                        },
                    },
                    "required": ["instance_id"],
                },
            },
            "display": _DISPLAY_PROPS,
        },
        "required": ["mochi_item_id", "display"],
    }

    def __init__(self, item_reader: ItemReader):
        self._read = item_reader

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        try:
            mochi_item_id = UUID(str(args.get("mochi_item_id")))
        except (ValueError, TypeError):
            return _error("invalid mochi_item_id")
        item = await self._read(owner_id, mochi_item_id)
        if item is None:
            return _error("record not found")

        changes = {
            key: value
            for key, value in (args.get("changes") or {}).items()
            if key in {"text", "user_memo", "summary"} and isinstance(value, str)
        }
        instance_changes: list[dict[str, Any]] = []
        for raw in args.get("instance_changes") or []:
            try:
                instance_id = UUID(str(raw.get("instance_id")))
            except (ValueError, TypeError):
                return _error("invalid instance_id")
            instance = next((i for i in item.intent_instances if i.id == instance_id), None)
            if instance is None:
                return _error(f"instance {instance_id} not found on this record")
            entry: dict[str, Any] = {"instance_id": str(instance_id)}
            payload_fields = {
                key: value
                for key, value in (raw.get("payload") or {}).items()
                if key in _PAYLOAD_FIELD_PROPS and isinstance(value, str)
            }
            if payload_fields:
                entry["payload"] = payload_fields
            if isinstance(raw.get("label"), str):
                entry["label"] = raw["label"]
            if isinstance(raw.get("lifecycle"), dict):
                target = _parse_lifecycle(raw["lifecycle"])
                if target is None:
                    return _error("invalid lifecycle target")
                # 전이 합법성 사전 검증 — 불법이면 카드 자체를 만들지 않는다.
                if instance.lifecycle != target and not is_allowed(
                    instance.intent_type, instance.lifecycle, target
                ):
                    return _error(
                        f"illegal lifecycle transition for {instance.intent_type.value}: "
                        f"{instance.lifecycle.kind.value} → {target.kind.value}"
                    )
                entry["lifecycle"] = {
                    "to": target.kind.value,
                    "archive_reason": target.archive_reason.value if target.archive_reason else None,
                }
            instance_changes.append(entry)

        if not changes and not instance_changes:
            return _error("nothing to change — provide changes or instance_changes")
        return _card(
            "item_update",
            {
                "mochi_item_id": str(mochi_item_id),
                "changes": changes,
                "instance_changes": instance_changes,
                "display": _display(args, "기록을 이렇게 바꿀까요?"),
            },
            summary="수정 카드를 준비했어요",
        )


class ProposeItemDeleteTool:
    name = "propose_item_delete"
    label = "삭제 카드를 준비하고 있어요"
    description = (
        "Propose deleting a record. Destructive — always goes through the confirmation card; "
        "never claim a record was deleted."
    )
    parameters: dict[str, Any] = {
        "type": "object",
        "properties": {"mochi_item_id": {"type": "string"}, "display": _DISPLAY_PROPS},
        "required": ["mochi_item_id", "display"],
    }

    def __init__(self, item_reader: ItemReader):
        self._read = item_reader

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        try:
            mochi_item_id = UUID(str(args.get("mochi_item_id")))
        except (ValueError, TypeError):
            return _error("invalid mochi_item_id")
        if await self._read(owner_id, mochi_item_id) is None:
            return _error("record not found")
        return _card(
            "item_delete",
            {"mochi_item_id": str(mochi_item_id), "display": _display(args, "이 기록을 지울까요?")},
            summary="삭제 카드를 준비했어요",
        )


class ProposeCreateScheduleTool:
    name = "propose_create_schedule"
    label = "일정 카드를 준비하고 있어요"
    description = (
        "Propose creating a schedule record (calendar entry) the user asked for. Requires a "
        "concrete title and date. On confirm it is saved as-is without re-analysis, so fill "
        "the fields exactly as agreed in conversation."
    )
    parameters: dict[str, Any] = {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "date": {"type": "string", "description": "ISO date the event starts, e.g. 2026-06-12"},
            "time": {"type": "string", "description": "HH:MM if known"},
            "end_date": {
                "type": "string",
                "description": "ISO date the event ends — multi-day events only, omit for a single day",
            },
            "end_time": {"type": "string", "description": "HH:MM the event ends, if known"},
            "person": {"type": "string"},
            "note": {"type": "string"},
            "display": _DISPLAY_PROPS,
        },
        "required": ["title", "date", "display"],
    }

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        title = args.get("title")
        date = args.get("date")
        if not isinstance(title, str) or not title.strip():
            return _error("title is required")
        parsed_start = _parse_iso(date) if isinstance(date, str) else None
        if parsed_start is None:
            return _error("date must be ISO format (e.g. 2026-06-12)")
        end_date = args.get("end_date")
        if isinstance(end_date, str) and end_date:
            parsed_end = _parse_iso(end_date)
            if parsed_end is None:
                return _error("end_date must be ISO format (e.g. 2026-06-14)")
            if parsed_end < parsed_start:
                return _error("end_date is before date — a range must end at or after its start")
        payload = {
            key: args[key]
            for key in ("title", "date", "time", "end_date", "end_time", "person", "note")
            if isinstance(args.get(key), str) and args[key]
        }
        return _card(
            "create_schedule",
            {
                "confirmed_instances": [{"intent_type": "schedule", "payload": payload}],
                "text": payload.get("note") or title,
                "display": _display(args, f"일정 '{title}' 을 추가할까요?"),
            },
            summary="일정 카드를 준비했어요",
        )


class ProposeReminderTool:
    name = "propose_reminder"
    label = "알림 카드를 준비하고 있어요"
    description = (
        "Propose a one-shot local reminder notification on the user's device. fire_at must be "
        "a future ISO datetime resolved against the current KST time from your context."
    )
    parameters: dict[str, Any] = {
        "type": "object",
        "properties": {
            "fire_at": {"type": "string", "description": "ISO datetime, KST assumed if no offset"},
            "title": {"type": "string"},
            "related_mochi_item_id": {"type": "string"},
            "display": _DISPLAY_PROPS,
        },
        "required": ["fire_at", "title", "display"],
    }

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        title = args.get("title")
        fire_at = _parse_iso(str(args.get("fire_at") or ""))
        if not isinstance(title, str) or not title.strip():
            return _error("title is required")
        if fire_at is None:
            return _error("fire_at must be ISO datetime")
        if fire_at <= datetime.now(_KST):
            return _error("fire_at is in the past — resolve against current time first")
        payload: dict[str, Any] = {
            # microsecond 절삭 — iOS ISO8601 파서는 3자리 fractional 만 받아 6자리면
            # proposal 이 silent drop 된다 (리뷰 P2). 알림에 초 이하 정밀도는 무의미.
            "fire_at": fire_at.replace(microsecond=0).isoformat(),
            "title": title,
            "display": _display(args, f"'{title}' 알림을 맞출까요?"),
        }
        raw_related = args.get("related_mochi_item_id")
        if isinstance(raw_related, str):
            with suppress(ValueError):
                payload["related_mochi_item_id"] = str(UUID(raw_related))
        return _card("reminder", payload, summary="알림 카드를 준비했어요")


class ProposeCreateMemoTool:
    name = "propose_create_memo"
    label = "메모 카드를 준비하고 있어요"
    description = (
        "Propose saving what the user said as a new memo record ('기록해줘'). The text is "
        "saved through the normal analysis pipeline after confirmation."
    )
    parameters: dict[str, Any] = {
        "type": "object",
        "properties": {"text": {"type": "string"}, "display": _DISPLAY_PROPS},
        "required": ["text", "display"],
    }

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        memo_text = args.get("text")
        if not isinstance(memo_text, str) or not memo_text.strip():
            return _error("text is required")
        return _card(
            "create_memo",
            {"text": memo_text.strip(), "display": _display(args, "이 내용을 기록해둘까요?")},
            summary="메모 카드를 준비했어요",
        )


def _parse_iso(raw: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_KST)
    return parsed


def _parse_lifecycle(raw: dict[str, Any]) -> InstanceLifecycleState | None:
    try:
        kind = InstanceLifecycleKind(str(raw.get("to")))
        reason_raw = raw.get("archive_reason")
        reason = ArchiveReason(str(reason_raw)) if reason_raw else None
    except ValueError:
        return None
    # archive_reason 은 archived 에서만 의미 — 비-archived 전이에 끼면 무시 (도메인 위생, 리뷰 P2).
    if kind is not InstanceLifecycleKind.ARCHIVED:
        reason = None
    return InstanceLifecycleState(kind=kind, archive_reason=reason)
