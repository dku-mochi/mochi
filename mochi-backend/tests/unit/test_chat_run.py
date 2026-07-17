"""채팅 run 루프 단위 테스트 — fake LLM/Store 주입.

고정하는 보장: ① 툴 루프(영속·이벤트 순서·citation) ② 한도 초과는 에러가 아니라 폴백 답변
③ 타임아웃 → failed + error 이벤트 ④ 루프 read-only(레지스트리에 쓰기 툴 없음)
⑤ BeginChatTurn 의 암묵 생성·동시 run 409 ⑥ 클라 이탈과 무관한 완주는 구조상 보장
(detached task + ChatTurnStore 즉시 영속 — 본 테스트의 store 호출 기록이 그 증거).
"""

import asyncio
from collections.abc import AsyncIterator
from typing import Any
from uuid import UUID, uuid4

import pytest

from app.modules.conversations.application.begin_chat_turn import (
    BeginChatTurn,
    RunInProgressError,
)
from app.modules.conversations.application.run_chat_turn import (
    _CITATION_PATTERN,
    RunChatTurn,
)
from app.modules.conversations.domain.entities import (
    Conversation,
    Message,
    MessageRole,
    RunStatus,
)
from app.modules.conversations.domain.ports import (
    ChatLLMChunk,
    ChatTool,
    ChatToolResult,
    ResolvedCitation,
)
from app.modules.conversations.domain.run_events import ChatEvent
from app.modules.conversations.infrastructure.run_registry import RunRegistry
from app.modules.conversations.prompts.chat_prompts import ACTIVE_CHAT_PROMPT

_OWNER = uuid4()
_CONVERSATION = uuid4()
_KNOWN_ITEM = UUID("11111111-1111-1111-1111-111111111111")
_UNKNOWN_ITEM = UUID("22222222-2222-2222-2222-222222222222")


class FakeLLM:
    """라운드별 스크립트 — stream() 호출마다 다음 라운드 chunk 들을 흘린다."""

    def __init__(self, rounds: list[list[ChatLLMChunk]]):
        self._rounds = list(rounds)
        self.calls: list[dict[str, Any]] = []

    def stream(
        self,
        *,
        system_prompt: str,
        contents: list[dict[str, Any]],
        tools: list[ChatTool],
        force_tool: bool = False,
    ) -> AsyncIterator[ChatLLMChunk]:
        self.calls.append(
            {
                "system_prompt": system_prompt,
                "contents": [dict(p) for p in contents],
                "tool_names": [t.name for t in tools],
                "force_tool": force_tool,
            }
        )
        chunks = self._rounds.pop(0) if self._rounds else []

        async def _gen() -> AsyncIterator[ChatLLMChunk]:
            for chunk in chunks:
                yield chunk

        return _gen()


class SleepyLLM:
    def stream(self, **_: Any) -> AsyncIterator[ChatLLMChunk]:
        async def _gen() -> AsyncIterator[ChatLLMChunk]:
            await asyncio.sleep(10)
            yield ChatLLMChunk(text_delta="늦은 답")

        return _gen()


class FakeStore:
    """in-memory ChatTurnStore — 호출 기록이 곧 영속 증거."""

    def __init__(self, history: list[Message] | None = None, known_items: set[UUID] | None = None):
        self.history = history or []
        self.appended: list[Message] = []
        self.statuses: list[tuple[UUID, RunStatus]] = []
        self.known_items = known_items if known_items is not None else {_KNOWN_ITEM}

    async def load_history(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        return list(self.history)

    async def append(self, *, owner_id: UUID, message: Message) -> bool:
        self.appended.append(message)
        return True

    async def set_run_status(self, *, owner_id: UUID, run_id: UUID, status: RunStatus) -> bool:
        self.statuses.append((run_id, status))
        return True

    async def resolve_citations(
        self, *, owner_id: UUID, mochi_item_ids: list[UUID]
    ) -> list[ResolvedCitation]:
        return [
            ResolvedCitation(mochi_item_id=i, title="제목", snippet="발췌")
            for i in mochi_item_ids
            if i in self.known_items
        ]


class FakeSearchTool:
    name = "search_items"
    label = "기록을 뒤지고 있어요"
    description = "search"
    parameters: dict[str, Any] = {"type": "object", "properties": {}}

    def __init__(self, *, fail: bool = False):
        self.fail = fail
        self.calls: list[dict[str, Any]] = []

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        self.calls.append(args)
        if self.fail:
            raise RuntimeError("boom")
        return ChatToolResult(
            payload={"items": [{"id": str(_KNOWN_ITEM), "snippet": "카페"}], "count": 1},
            summary="기록 1개를 찾았어요",
            compact={"items": [{"id": str(_KNOWN_ITEM)}]},
        )


async def _drain(queue: "asyncio.Queue[ChatEvent | None]") -> list[ChatEvent]:
    events: list[ChatEvent] = []
    while True:
        event = await queue.get()
        if event is None:
            return events
        events.append(event)


def _runner(
    llm: Any, store: FakeStore, registry: RunRegistry, tools: list[Any] | None = None, **kwargs: Any
) -> RunChatTurn:
    return RunChatTurn(
        llm=llm,
        tools=tools if tools is not None else [FakeSearchTool()],
        store=store,
        registry=registry,
        prompt=ACTIVE_CHAT_PROMPT,
        timeout_seconds=kwargs.pop("timeout_seconds", 5.0),
        **kwargs,
    )


# ---------- ① 툴 루프 풀 플로우 ----------


async def test_full_flow_persists_steps_and_streams_events_in_order() -> None:
    answer = f"근처에 좋은 카페가 있어요【item:{_KNOWN_ITEM}】 모르는 출처【item:{_UNKNOWN_ITEM}】"
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("search_items", {"query": "카페"}))],
            [ChatLLMChunk(text_delta="근처에 좋은 "), ChatLLMChunk(text_delta=answer[len("근처에 좋은 ") :])],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)
    tool = FakeSearchTool()

    await _runner(llm, store, registry, tools=[tool]).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    # 이벤트 순서: tool_started → tool_finished → message_delta×2 → citation → done
    kinds = [e.kind for e in events]
    assert kinds == ["tool_started", "tool_finished", "message_delta", "message_delta", "citation", "done"]
    assert all(e.payload["run_id"] == str(run_id) for e in events)

    # 영속: tool 행 + assistant 행 (citations 는 실재 item 만 — 미실재 마커는 본문 보존·citation 미생성)
    assert [m.role for m in store.appended] == [MessageRole.TOOL, MessageRole.ASSISTANT]
    tool_row = store.appended[0]
    assert tool_row.tool_name == "search_items"
    assert tool_row.tool_payload is not None and tool_row.tool_payload["args"] == {"query": "카페"}
    assistant = store.appended[1]
    assert str(_UNKNOWN_ITEM) in (assistant.content or "")  # 본문 보존
    assert [c.mochi_item_id for c in assistant.citations] == [_KNOWN_ITEM]
    assert assistant.citations[0].citation_index == 1
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]
    # 2라운드째 contents 에 함수호출/응답이 재구성돼 들어갔다
    assert any("function_responses" in p for p in llm.calls[1]["contents"])


def test_citation_pattern_accepts_fullwidth_and_ascii_brackets() -> None:
    # flash-lite 가 canonical 전각 「【】」 대신 반각 「[]」 으로 마커를 흘려도 citation 을
    # 잡아야 한다 — 안 잡으면 본문에 마커 원문이 그대로 노출된다(실기기 리포트 2026-06-15).
    fid = "b63546c1-1d56-4882-94ba-6cc035dcf680"
    assert _CITATION_PATTERN.findall(f"과제【item:{fid}】 챙겨요") == [fid]
    assert _CITATION_PATTERN.findall(f"과제[item:{fid}] 챙겨요") == [fid]
    assert _CITATION_PATTERN.findall("과제[item:b63546c1] 챙겨요") == ["b63546c1"]
    # 일반 본문 대괄호와 임의 문자열은 오탐하지 않는다(item: + 8자리 hex 최소).
    assert _CITATION_PATTERN.findall("배열[0] 과 [item:not-a-uuid] 는 무시") == []


async def test_short_citation_id_resolves_only_from_current_tool_results() -> None:
    short = str(_KNOWN_ITEM)[:8]
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("search_items", {"query": "카페"}))],
            [ChatLLMChunk(text_delta=f"저장한 카페예요[item:{short}]")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    assistant = store.appended[-1]
    assert [citation.mochi_item_id for citation in assistant.citations] == [_KNOWN_ITEM]
    citation_event = next(event for event in events if event.kind == "citation")
    assert citation_event.payload["item_id"] == str(_KNOWN_ITEM)


async def test_first_round_forces_tool_call_then_releases() -> None:
    # '답하기 전 검색'은 프롬프트(③)가 아니라 기계(②)로 보장한다 — 턴의 첫 라운드만
    # mode=ANY(force_tool), 이후 라운드와 폴백 라운드는 AUTO 로 풀려 답변이 나올 수 있다.
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("search_items", {"query": "카페"}))],
            [ChatLLMChunk(text_delta="좋은 카페가 있어요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    await _drain(queue)

    assert [c["force_tool"] for c in llm.calls] == [True, False]


async def test_parallel_tool_calls_grouped_into_single_turn_with_signature() -> None:
    # thinking 활성 시 thought_signature 는 라운드 첫 fc part 에만 온다 — 병렬 콜을
    # 콜마다 별도 model/user turn 으로 쪼개면 Gemini 시그니처 검증(400)에 걸리므로,
    # 한 라운드의 fc/fr 는 각각 하나의 entry 에 다중 part 로 묶여야 한다 (리뷰 P1).
    signature = b"sig-round-1"
    llm = FakeLLM(
        rounds=[
            [
                ChatLLMChunk(tool_call=("search_items", {"query": "케이크"}), thought_signature=signature),
                ChatLLMChunk(tool_call=("search_items", {"query": "레스토랑"})),
            ],
            [ChatLLMChunk(text_delta="플랜을 짜봤어요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    await _drain(queue)

    contents = llm.calls[1]["contents"]
    call_groups = [p["function_calls"] for p in contents if "function_calls" in p]
    response_groups = [p["function_responses"] for p in contents if "function_responses" in p]
    assert len(call_groups) == 1 and len(response_groups) == 1
    assert [fc["name"] for fc in call_groups[0]] == ["search_items", "search_items"]
    assert [fc.get("thought_signature") for fc in call_groups[0]] == [signature, None]
    assert len(response_groups[0]) == 2


# ---------- 채팅용 페르소나 프로필 주입 ----------


def _one_shot_llm() -> FakeLLM:
    return FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("search_items", {}))],
            [ChatLLMChunk(text_delta="답해요")],
        ]
    )


async def test_chat_profile_injected_into_system_prompt() -> None:
    llm = _one_shot_llm()
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    async def _loader(owner_id: UUID) -> str | None:
        return "요즘 AI 공부에 빠진 개발자."

    await _runner(llm, store, registry, profile_loader=_loader).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    await _drain(queue)

    system_prompt = llm.calls[0]["system_prompt"]
    assert "요즘 AI 공부에 빠진 개발자." in system_prompt
    assert "Who you're speaking with" in system_prompt
    assert "{profile}" not in system_prompt  # 슬롯이 치환됨
    # 배경·톤 전용 가드(검색 회귀 방지) — 프로필이 사실 출처로 오용되지 않게 못박는 문구.
    assert "never a source for what you claim" in system_prompt


async def test_no_profile_loader_leaves_slot_empty() -> None:
    # 신규 유저(또는 loader 미주입) — 슬롯이 빈 문자열로 사라지고 V10 거동과 동일.
    llm = _one_shot_llm()
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    await _drain(queue)

    system_prompt = llm.calls[0]["system_prompt"]
    assert "{profile}" not in system_prompt
    assert "Who you're speaking with" not in system_prompt


async def test_profile_loader_failure_does_not_break_chat() -> None:
    # 프로필은 부가 — 로딩 실패가 답변을 막지 않는다(슬롯만 비고 정상 완료).
    llm = _one_shot_llm()
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    async def _boom(owner_id: UUID) -> str | None:
        raise RuntimeError("profile store down")

    await _runner(llm, store, registry, profile_loader=_boom).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    assert events[-1].kind == "done"
    assert "{profile}" not in llm.calls[0]["system_prompt"]
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


# ---------- ② 한도 초과 → 폴백 답변 (에러 아님) ----------


async def test_round_budget_exhaustion_forces_final_answer_without_tools() -> None:
    tool_round = [ChatLLMChunk(tool_call=("search_items", {}))]
    llm = FakeLLM(rounds=[tool_round, tool_round, [ChatLLMChunk(text_delta="여기까지 찾았어요")]])
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, max_rounds=3).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    assert llm.calls[2]["tool_names"] == []  # 마지막 라운드는 툴 비활성
    assert any(
        "Tool budget is exhausted" in p.get("text", "") for p in llm.calls[2]["contents"]
    )  # 폴백 지시 주입
    assert events[-1].kind == "done"  # error 가 아니라 정상 완료
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


async def test_call_budget_exhaustion_also_triggers_fallback() -> None:
    two_calls = [
        ChatLLMChunk(tool_call=("search_items", {})),
        ChatLLMChunk(tool_call=("search_items", {})),
    ]
    llm = FakeLLM(rounds=[two_calls, [ChatLLMChunk(text_delta="찾은 만큼 답해요")]])
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, max_tool_calls=2, max_rounds=5).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    await _drain(queue)

    assert llm.calls[1]["tool_names"] == []  # 콜 예산 소진 → 다음 라운드가 곧 final
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


# ---------- ③ 타임아웃·실패 경로 ----------


async def test_timeout_marks_failed_and_emits_error_event() -> None:
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(SleepyLLM(), store, registry, timeout_seconds=0.05).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    assert store.statuses == [(run_id, RunStatus.FAILED)]
    assert events[-1].kind == "error"
    assert events[-1].payload["code"] == "chat.run_timeout"


async def test_empty_answer_marks_failed() -> None:
    llm = FakeLLM(rounds=[[]])
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    events = await _drain(queue)

    assert store.statuses == [(run_id, RunStatus.FAILED)]
    assert events[-1].kind == "error"


async def test_tool_failure_is_fed_back_not_fatal() -> None:
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("search_items", {}))],
            [ChatLLMChunk(text_delta="검색이 잠깐 막혔지만 아는 만큼 답해요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, tools=[FakeSearchTool(fail=True)]).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    events = await _drain(queue)

    assert events[-1].kind == "done"
    assert any(
        "error" in fr.get("response", {})
        for p in llm.calls[1]["contents"]
        for fr in p.get("function_responses", [])
    )
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


async def test_unknown_tool_call_recovers_without_persisting_row() -> None:
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("hack_the_db", {}))],
            [ChatLLMChunk(text_delta="그 도구는 없어서 그냥 답할게요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    await _drain(queue)

    assert [m.role for m in store.appended] == [MessageRole.ASSISTANT]  # tool 행 미영속
    assert store.statuses == [(run_id, RunStatus.COMPLETED)]


# ---------- ④ 루프 read-only — 라우터 툴 레지스트리에 쓰기 툴 없음 ----------


def test_router_tool_registry_is_read_only() -> None:
    # _chat_tools 는 실제 settings(.env)를 읽어 환경 의존이라, 구성 규칙은 순수 빌더로 고정.
    from app.modules.conversations.presentation.router import _build_chat_tools

    # 쓰기 가능 툴 추가는 의식적 결정이어야 한다 — propose_* 도 검증 후 카드 payload 만
    # 반환하는 read-only. 이 목록을 갱신할 땐 해당 툴이 DB 를 쓰지 않음을 리뷰로 보장할 것.
    base = {
        "search_items",
        "get_item_detail",
        "list_notifications",
        "propose_item_update",
        "propose_item_delete",
        "propose_create_schedule",
        "propose_reminder",
        "propose_create_memo",
        "propose_reschedule_notification",
        "propose_cancel_notification",
        "web_fetch",
    }
    session_factory: Any = object()  # 빌더는 팩토리를 보관만 한다 — 호출 없음

    bare = {
        tool.name for tool in _build_chat_tools(session_factory, tavily_api_key=None, gcs_capture_bucket=None)
    }
    assert bare == base

    # web_search 는 키가 있을 때만 — 키 발급이 머지를 블록하지 않는 설계 (journal 2026-06-10).
    # view_item_image 는 버킷이 있을 때만 — 없는데 등록하면 항상 "no image" 로 모델을 오도.
    full = {
        tool.name
        for tool in _build_chat_tools(
            session_factory, tavily_api_key="tvly-x", gcs_capture_bucket="mochi-captures"
        )
    }
    assert full == base | {"web_search", "view_item_image"}


# ---------- ⑤ BeginChatTurn ----------


class _BeginStubRepo:
    def __init__(self, *, existing: Conversation | None = None, running: bool = False):
        self.existing = existing
        self.running = running
        self.created: list[Conversation] = []
        self.stale_repairs = 0
        self.messages: list[Message] = []

    async def find_by_id(self, *, owner_id: UUID, conversation_id: UUID) -> Conversation | None:
        return self.existing

    async def create(self, *, owner_id: UUID, conversation: Conversation) -> None:
        self.created.append(conversation)

    async def mark_stale_runs_failed(
        self, *, owner_id: UUID, conversation_id: UUID, started_before: Any
    ) -> int:
        self.stale_repairs += 1
        return 0

    async def has_running_run(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        return self.running

    async def add_message(self, *, owner_id: UUID, message: Message) -> bool:
        self.messages.append(message)
        return True


async def test_begin_creates_conversation_implicitly_with_truncated_title() -> None:
    repo = _BeginStubRepo()
    conversation_id = uuid4()

    message = await BeginChatTurn(repository=repo).execute(
        owner_id=_OWNER, conversation_id=conversation_id, text="가" * 80
    )

    assert len(repo.created) == 1
    assert repo.created[0].id == conversation_id
    assert repo.created[0].title is not None and len(repo.created[0].title) == 40
    assert repo.stale_repairs == 1
    assert message.run_status is RunStatus.RUNNING
    assert message.run_id is not None and message.run_started_at is not None
    assert repo.messages == [message]


async def test_begin_rejects_concurrent_run() -> None:
    repo = _BeginStubRepo(existing=Conversation(id=uuid4()), running=True)

    with pytest.raises(RunInProgressError):
        await BeginChatTurn(repository=repo).execute(owner_id=_OWNER, conversation_id=uuid4(), text="질문")
    assert repo.messages == []  # user 행 미영속


# ---------- ⑤ Gemini 클라이언트의 force_tool → mode 매핑 (②티어 경계) ----------


async def test_gemini_client_maps_force_tool_to_any_mode(monkeypatch: Any) -> None:
    from app.modules.conversations.infrastructure import gemini_chat_client as mod

    captured: list[Any] = []

    class _FakeModels:
        async def generate_content_stream(self, *, model: str, contents: Any, config: Any) -> Any:
            captured.append(config)

            async def _gen() -> AsyncIterator[Any]:
                return
                yield  # pragma: no cover — 빈 스트림

            return _gen()

    class _FakeAio:
        models = _FakeModels()

    class _FakeClient:
        aio = _FakeAio()

    monkeypatch.setattr(mod, "_shared_client", lambda: _FakeClient())
    client = mod.GeminiChatClient(model="test-model")
    kwargs: dict[str, Any] = {
        "system_prompt": "s",
        "contents": [{"role": "user", "text": "안녕"}],
        "tools": [FakeSearchTool()],
    }

    async for _ in client.stream(**kwargs, force_tool=True):
        pass
    async for _ in client.stream(**kwargs):
        pass

    modes = [c.tool_config.function_calling_config.mode for c in captured]
    assert "ANY" in str(modes[0]) and "AUTO" in str(modes[1])
