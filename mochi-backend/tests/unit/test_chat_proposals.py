"""채팅 proposal 경로 단위 테스트 (PR-3).

고정하는 보장: ① propose_* 는 검증 실패 시 카드를 만들지 않는다(불법 전이·미실재 대상)
② run 루프가 proposal 을 SSE 이벤트로 흘리고 assistant 행에 영속한다
③ confirmedInstances ingest 는 분석 파이프라인을 생략한다(§5.2 예외 — outbox 미적재·즉시 analyzed)
④ UpdateMochiItem 은 콘텐츠+instance 를 한 트랜잭션 의미로 — payload 병합·불법 전이 409·미실재 404.
"""

from datetime import datetime, timedelta
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest

from app.core.error_envelope import ConflictError, NotFoundError
from app.modules.conversations.domain.entities import MessageRole, RunStatus
from app.modules.conversations.domain.ports import ChatLLMChunk
from app.modules.conversations.infrastructure.run_registry import RunRegistry
from app.modules.conversations.infrastructure.tools.propose import (
    ProposeCreateMemoTool,
    ProposeCreateScheduleTool,
    ProposeItemDeleteTool,
    ProposeItemUpdateTool,
    ProposeReminderTool,
)
from app.modules.mochi_items.application.ingest import Ingest, IngestCommand
from app.modules.mochi_items.application.update_mochi_item import (
    InstanceChange,
    UpdateMochiItem,
    UpdateMochiItemCommand,
)
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
    IntentPayload,
)
from app.shared.intent import Intent
from tests.unit.test_chat_run import FakeLLM, FakeStore, _drain, _runner

_OWNER = uuid4()


def _item_with_instance(intent: Intent = Intent.SCHEDULE) -> MochiItem:
    instance = IntentInstance(
        intent_type=intent,
        payload=IntentPayload(title="민수 약속", date="2026-06-12", time="13:00"),
        label="약속",
    )
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.CHAT, text="원문"),
        intent_instances=(instance,),
    )


def _reader_for(item: MochiItem | None):
    async def _read(owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        return item

    return _read


_DISPLAY = {"display": {"title": "카드"}}


# ---------- ① propose_* 검증 ----------


async def test_propose_update_rejects_illegal_lifecycle_without_card() -> None:
    item = _item_with_instance(Intent.SCHEDULE)
    tool = ProposeItemUpdateTool(_reader_for(item))

    result = await tool.run(
        owner_id=_OWNER,
        args={
            "mochi_item_id": str(item.id),
            # schedule 은 active→decaying 전이가 불법.
            "instance_changes": [
                {
                    "instance_id": str(item.intent_instances[0].id),
                    "lifecycle": {"to": "decaying"},
                }
            ],
            **_DISPLAY,
        },
    )

    assert result.proposal is None
    assert "illegal" in result.payload["error"]


async def test_propose_update_builds_card_with_merge_fields_and_transition() -> None:
    item = _item_with_instance(Intent.TODO)
    tool = ProposeItemUpdateTool(_reader_for(item))

    result = await tool.run(
        owner_id=_OWNER,
        args={
            "mochi_item_id": str(item.id),
            "changes": {"user_memo": "수정된 메모"},
            "instance_changes": [
                {
                    "instance_id": str(item.intent_instances[0].id),
                    "payload": {"time": "15:00"},
                    "lifecycle": {"to": "archived", "archive_reason": "todoCompleted"},
                }
            ],
            **_DISPLAY,
        },
    )

    assert result.proposal is not None
    payload = result.proposal["payload"]
    assert payload["changes"] == {"user_memo": "수정된 메모"}
    assert payload["instance_changes"][0]["payload"] == {"time": "15:00"}
    assert payload["instance_changes"][0]["lifecycle"]["to"] == "archived"


async def test_propose_update_unknown_instance_or_item_yields_error() -> None:
    item = _item_with_instance()
    tool = ProposeItemUpdateTool(_reader_for(item))
    result = await tool.run(
        owner_id=_OWNER,
        args={
            "mochi_item_id": str(item.id),
            "instance_changes": [{"instance_id": str(uuid4()), "payload": {"time": "15:00"}}],
            **_DISPLAY,
        },
    )
    assert result.proposal is None

    missing = ProposeItemDeleteTool(_reader_for(None))
    result = await missing.run(owner_id=_OWNER, args={"mochi_item_id": str(uuid4()), **_DISPLAY})
    assert result.proposal is None


async def test_propose_schedule_requires_title_and_iso_date() -> None:
    tool = ProposeCreateScheduleTool()
    bad = await tool.run(owner_id=_OWNER, args={"title": "회의", "date": "내일", **_DISPLAY})
    assert bad.proposal is None

    good = await tool.run(
        owner_id=_OWNER, args={"title": "회의", "date": "2026-06-12", "time": "15:00", **_DISPLAY}
    )
    assert good.proposal is not None
    instance = good.proposal["payload"]["confirmed_instances"][0]
    assert instance["intent_type"] == "schedule"
    assert instance["payload"]["time"] == "15:00"


async def test_propose_schedule_range_validates_and_carries_end_date() -> None:
    tool = ProposeCreateScheduleTool()
    # 끝이 시작보다 앞서면 카드 자체를 만들지 않는다 — 모델이 정정하게 에러로 돌려준다.
    inverted = await tool.run(
        owner_id=_OWNER,
        args={"title": "워크숍", "date": "2026-06-14", "end_date": "2026-06-12", **_DISPLAY},
    )
    assert inverted.proposal is None

    ranged = await tool.run(
        owner_id=_OWNER,
        args={"title": "워크숍", "date": "2026-06-12", "end_date": "2026-06-14", **_DISPLAY},
    )
    assert ranged.proposal is not None
    payload = ranged.proposal["payload"]["confirmed_instances"][0]["payload"]
    assert payload["date"] == "2026-06-12"
    assert payload["end_date"] == "2026-06-14"


async def test_propose_reminder_rejects_past_fire_at() -> None:
    tool = ProposeReminderTool()
    past = (datetime.now(ZoneInfo("Asia/Seoul")) - timedelta(hours=1)).isoformat()
    result = await tool.run(owner_id=_OWNER, args={"fire_at": past, "title": "알림", **_DISPLAY})
    assert result.proposal is None

    future = (datetime.now(ZoneInfo("Asia/Seoul")) + timedelta(hours=1)).isoformat()
    result = await tool.run(owner_id=_OWNER, args={"fire_at": future, "title": "알림", **_DISPLAY})
    assert result.proposal is not None


async def test_propose_memo_requires_text() -> None:
    tool = ProposeCreateMemoTool()
    assert (await tool.run(owner_id=_OWNER, args={"text": "  ", **_DISPLAY})).proposal is None
    result = await tool.run(owner_id=_OWNER, args={"text": "우유 사기", **_DISPLAY})
    assert result.proposal is not None
    assert result.proposal["payload"]["text"] == "우유 사기"


async def test_propose_update_strips_archive_reason_on_non_archived_transition() -> None:
    # archived→active 완료취소에 archiveReason 이 끼면 active 행에 reason 이 영속되는
    # 도메인 위생 위반 — 카드 단계에서 무시한다 (리뷰 P2).
    instance = IntentInstance(
        intent_type=Intent.TODO,
        payload=IntentPayload(title="할일"),
        lifecycle=InstanceLifecycleState(
            kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
        ),
    )
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.CHAT, text="원문"),
        intent_instances=(instance,),
    )
    tool = ProposeItemUpdateTool(_reader_for(item))

    result = await tool.run(
        owner_id=_OWNER,
        args={
            "mochi_item_id": str(item.id),
            "instance_changes": [
                {
                    "instance_id": str(instance.id),
                    "lifecycle": {"to": "active", "archive_reason": "todoCompleted"},
                }
            ],
            **_DISPLAY,
        },
    )

    assert result.proposal is not None
    assert result.proposal["payload"]["instance_changes"][0]["lifecycle"] == {
        "to": "active",
        "archive_reason": None,
    }


def test_active_chat_prompt_is_v5_with_proposal_web_and_loose_search_rules() -> None:
    # V2~V5 는 직전 버전의 body.replace 파생 — 상류 본문이 바뀌면 replace 가 silent no-op
    # 으로 구 규칙이 부활한다 (리뷰 P2). 활성 프롬프트의 행동·grounding 규칙을 고정.
    from app.modules.conversations.prompts.chat_prompts import (
        ACTIVE_CHAT_PROMPT,
        CHAT_V1,
        CHAT_V2,
        CHAT_V3,
        CHAT_V4,
        CHAT_V5,
    )

    assert ACTIVE_CHAT_PROMPT is CHAT_V5
    assert CHAT_V2.body != CHAT_V1.body, "V1 anchor 불일치 — replace 가 no-op"
    assert CHAT_V3.body != CHAT_V2.body, "V2 anchor 불일치 — replace 가 no-op"
    assert CHAT_V4.body != CHAT_V3.body, "V3 anchor 불일치 — replace 가 no-op"
    assert CHAT_V5.body != CHAT_V4.body, "V4 anchor 불일치 — replace 가 no-op"
    assert "propose_" in ACTIVE_CHAT_PROMPT.body
    assert "currently cannot modify" not in ACTIVE_CHAT_PROMPT.body
    # PR-4 web 툴: 출처 3원 구분 + citation 마커는 기록 전용.
    assert "web-sourced" in ACTIVE_CHAT_PROMPT.body
    assert "markers are for records only" in ACTIVE_CHAT_PROMPT.body
    # V4: 구조 필드(날짜 등) 수정은 instance_changes payload 로 — text 치환 금지.
    assert "instance_changes" in ACTIVE_CHAT_PROMPT.body
    # V5: 사용자는 4-Intent 를 모른다 → 어휘로 intent_type 필터 금지 + 회상은 러프 브라우즈.
    assert "Leave intent_type unset" in ACTIVE_CHAT_PROMPT.body
    assert "Match loosely" in ACTIVE_CHAT_PROMPT.body


# ---------- ② run 루프의 proposal 이벤트·영속 ----------


class _ProposingTool:
    name = "propose_create_memo"
    label = "메모 카드를 준비하고 있어요"
    description = "d"
    parameters: dict[str, Any] = {"type": "object", "properties": {}}

    async def run(self, *, owner_id: UUID, args: dict[str, Any]):
        return await ProposeCreateMemoTool().run(owner_id=owner_id, args=args)


async def test_run_loop_streams_proposal_event_and_persists_on_assistant_row() -> None:
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("propose_create_memo", {"text": "우유 사기", **_DISPLAY}))],
            [ChatLLMChunk(text_delta="메모 카드를 준비했어요 — 확인해 주세요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, tools=[_ProposingTool()]).execute(
        owner_id=_OWNER, conversation_id=uuid4(), run_id=run_id
    )
    events = await _drain(queue)

    proposal_events = [e for e in events if e.kind == "proposal"]
    assert len(proposal_events) == 1
    assert proposal_events[0].payload["type"] == "create_memo"
    assert proposal_events[0].payload["payload"]["text"] == "우유 사기"

    assistant = next(m for m in store.appended if m.role is MessageRole.ASSISTANT)
    assert len(assistant.proposals) == 1
    assert assistant.proposals[0]["type"] == "create_memo"
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


# ---------- ③ confirmedInstances ingest — 분석 생략 (§5.2 예외) ----------


class _IngestStubRepo:
    def __init__(self) -> None:
        self.added: list[MochiItem] = []
        self.idempotency: dict[str, UUID] = {}

    async def already_ingested(self, *, owner_id: UUID, idempotency_key: str) -> MochiItem | None:
        existing = self.idempotency.get(idempotency_key)
        return next((i for i in self.added if i.id == existing), None) if existing else None

    async def add(self, *, owner_id: UUID, item: MochiItem) -> None:
        self.added.append(item)

    async def remember_idempotency(
        self, *, owner_id: UUID, idempotency_key: str, mochi_item_id: UUID
    ) -> None:
        self.idempotency[idempotency_key] = mochi_item_id


class _SpyNotifier:
    def __init__(self) -> None:
        self.emitted: list[UUID] = []

    async def emit(self, *, owner_id: UUID, mochi_item_id: UUID) -> None:
        self.emitted.append(mochi_item_id)


def _confirmed_command(key: str = "k1") -> IngestCommand:
    return IngestCommand(
        owner_id=_OWNER,
        channel=IngestChannel.CHAT,
        url=None,
        text="회의",
        user_memo=None,
        idempotency_key=key,
        confirmed_instances=(
            IntentInstance(
                intent_type=Intent.SCHEDULE,
                payload=IntentPayload(title="회의", date="2026-06-12"),
            ),
        ),
    )


async def test_confirmed_instances_skip_analysis_pipeline() -> None:
    repo = _IngestStubRepo()
    notifier = _SpyNotifier()

    result = await Ingest(repository=repo, notifier=notifier).execute(_confirmed_command())

    item = result.item
    assert notifier.emitted == []  # outbox 미적재 — 재분석이 확정을 덮지 않는다
    assert item.lifecycle.kind is LifecycleStateKind.ANALYZED
    assert item.intent_instances[0].intent_type is Intent.SCHEDULE
    assert item.intent_instances[0].lifecycle.kind is InstanceLifecycleKind.ACTIVE


async def test_confirmed_instances_ingest_is_idempotent() -> None:
    repo = _IngestStubRepo()
    notifier = _SpyNotifier()
    use_case = Ingest(repository=repo, notifier=notifier)

    first = await use_case.execute(_confirmed_command("same-key"))
    replay = await use_case.execute(_confirmed_command("same-key"))

    assert replay.was_idempotent_replay is True
    assert replay.item.id == first.item.id
    assert len(repo.added) == 1


async def test_plain_ingest_still_enters_pipeline() -> None:
    repo = _IngestStubRepo()
    notifier = _SpyNotifier()
    command = IngestCommand(
        owner_id=_OWNER,
        channel=IngestChannel.CHAT,
        url=None,
        text="우유 사기",
        user_memo=None,
        idempotency_key="k2",
    )

    result = await Ingest(repository=repo, notifier=notifier).execute(command)

    assert notifier.emitted == [result.item.id]  # memo 확정은 일반 ingestion — 분석 경유
    assert result.item.lifecycle.kind is LifecycleStateKind.INGESTED


# ---------- ④ UpdateMochiItem ----------


class _UpdateStubRepo:
    def __init__(self, item: MochiItem | None):
        self.item = item
        self.content_updates: list[dict[str, str | None]] = []
        self.field_updates: list[tuple[UUID, dict[str, str] | None, str | None]] = []
        self.lifecycle_updates: list[tuple[UUID, InstanceLifecycleState]] = []

    async def find_by_id(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        return self.item

    async def update_content(
        self, *, owner_id: UUID, mochi_item_id: UUID, text: str | None,
        user_memo: str | None, summary: str | None,
    ) -> bool:
        self.content_updates.append({"text": text, "user_memo": user_memo, "summary": summary})
        return True

    async def update_instance_fields(
        self, *, owner_id: UUID, mochi_item_id: UUID, instance_id: UUID,
        payload: dict[str, str] | None, label: str | None,
    ) -> bool:
        self.field_updates.append((instance_id, payload, label))
        return True

    async def update_instance_lifecycle(
        self, *, owner_id: UUID, mochi_item_id: UUID, instance_id: UUID,
        lifecycle: InstanceLifecycleState,
    ) -> bool:
        self.lifecycle_updates.append((instance_id, lifecycle))
        return True


async def test_update_merges_payload_and_applies_transition() -> None:
    item = _item_with_instance(Intent.TODO)
    instance = item.intent_instances[0]
    repo = _UpdateStubRepo(item)
    target = InstanceLifecycleState(
        kind=InstanceLifecycleKind.ARCHIVED, archive_reason=ArchiveReason.TODO_COMPLETED
    )

    await UpdateMochiItem(repository=repo).execute(
        UpdateMochiItemCommand(
            owner_id=_OWNER,
            mochi_item_id=item.id,
            user_memo="새 메모",
            instance_changes=(
                InstanceChange(
                    instance_id=instance.id,
                    payload_fields={"time": "15:00"},
                    lifecycle=target,
                ),
            ),
        )
    )

    assert repo.content_updates == [{"text": None, "user_memo": "새 메모", "summary": None}]
    instance_id, merged, _label = repo.field_updates[0]
    assert instance_id == instance.id
    # 병합 — 제공 필드(time)만 바뀌고 기존(title/date)은 보존.
    assert merged == {"title": "민수 약속", "date": "2026-06-12", "time": "15:00"}
    assert repo.lifecycle_updates == [(instance.id, target)]


async def test_update_rejects_illegal_transition_before_any_write() -> None:
    item = _item_with_instance(Intent.SCHEDULE)
    repo = _UpdateStubRepo(item)

    with pytest.raises(ConflictError):
        await UpdateMochiItem(repository=repo).execute(
            UpdateMochiItemCommand(
                owner_id=_OWNER,
                mochi_item_id=item.id,
                text="먼저 검증 — 이 콘텐츠 변경도 적용되면 안 된다",
                instance_changes=(
                    InstanceChange(
                        instance_id=item.intent_instances[0].id,
                        lifecycle=InstanceLifecycleState(kind=InstanceLifecycleKind.DECAYING),
                    ),
                ),
            )
        )
    assert repo.content_updates == []  # 검증 실패 시 쓰기 없음


async def test_update_missing_instance_is_404() -> None:
    item = _item_with_instance()
    repo = _UpdateStubRepo(item)

    with pytest.raises(NotFoundError):
        await UpdateMochiItem(repository=repo).execute(
            UpdateMochiItemCommand(
                owner_id=_OWNER,
                mochi_item_id=item.id,
                instance_changes=(
                    InstanceChange(instance_id=uuid4(), payload_fields={"time": "15:00"}),
                ),
            )
        )


async def test_update_missing_item_is_404() -> None:
    with pytest.raises(NotFoundError):
        await UpdateMochiItem(repository=_UpdateStubRepo(None)).execute(
            UpdateMochiItemCommand(owner_id=_OWNER, mochi_item_id=uuid4(), text="x")
        )
