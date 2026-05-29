"""Agent loop (orchestrator ANALYZED) 단위 테스트 — FakeLLM + fake gateway.

실제 Vertex 호출 없이 루프 제어만 검증:
- no-URL 단일 turn finalize → write-back
- webFetch turn → 되먹임 → finalize
- secondary intent dedup / applicability 매핑
- max_steps 소진 → graceful fail (failed 이벤트 + raise, write-back 없음)
"""

from uuid import uuid4

import pytest
from pydantic import BaseModel

from app.modules.agent.application.orchestrator import AgentOrchestrator
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.agent.domain.ports import LLMResponseChunk
from app.modules.agent.domain.tools import ToolName, ToolUsage
from app.shared.intent import Intent


class _ScriptedLLM:
    """미리 정한 chunk 들을 turn 마다 하나씩 흘린다."""

    def __init__(self, chunks: list[LLMResponseChunk]):
        self._chunks = chunks
        self.turns = 0

    async def stream(self, **_kwargs):
        chunk = self._chunks[self.turns]
        self.turns += 1
        yield chunk


class _LoopingLLM:
    """항상 webFetch 를 요청 — max_steps 소진 시나리오용."""

    async def stream(self, **_kwargs):
        yield LLMResponseChunk(
            tool_to_call=ToolName.WEB_FETCH, tool_arguments={"url": "https://example.com"}
        )


class _UrlInput(BaseModel):
    url: str


class _FakeWebFetchTool:
    name = ToolName.WEB_FETCH
    input_model = _UrlInput

    async def run(self, payload):
        class _Out(BaseModel):
            text: str = "fetched page text"
            final_url: str = "https://example.com"

        return _Out(), ToolUsage(tokens_in=1, tokens_out=1, latency_ms=1)


class _Registry:
    def __init__(self):
        self._t = {ToolName.WEB_FETCH: _FakeWebFetchTool()}

    def get(self, name):
        return self._t[name]

    def all(self):
        return list(self._t.values())


class _FakeGateway:
    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def list_recent_window(self, *, owner_id, limit):
        return []

    async def count_items(self, *, owner_id):
        return 0


def _finalize_chunk(intent="todo", summary="할 일 요약", **extra) -> LLMResponseChunk:
    payload = {
        "summary": summary,
        "intent": intent,
        "confidence": 0.9,
        "model_version": "test",
        **extra,
    }
    return LLMResponseChunk(final_payload=payload)


async def _drain(orch, item_id, owner_id):
    events = []
    async for ev in orch.run(item_id, owner_id):
        events.append(ev)
    return events


@pytest.mark.asyncio
async def test_no_url_single_turn_finalize_writes_back():
    gateway = _FakeGateway(
        AnalysisInput(text="다음 주까지 발표 대본 수정하기", url=None, user_memo=None)
    )
    orch = AgentOrchestrator(
        llm=_ScriptedLLM([_finalize_chunk(intent="todo")]),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
    )
    events = await _drain(orch, uuid4(), uuid4())
    assert gateway.applied is not None
    assert gateway.applied.intent is Intent.TODO
    assert gateway.applied.summary == "할 일 요약"
    assert any(e.kind == "final" for e in events)


@pytest.mark.asyncio
async def test_webfetch_then_finalize():
    gateway = _FakeGateway(AnalysisInput(text=None, url="https://example.com", user_memo=None))
    llm = _ScriptedLLM(
        [
            LLMResponseChunk(
                tool_to_call=ToolName.WEB_FETCH,
                tool_arguments={"url": "https://example.com"},
            ),
            _finalize_chunk(intent="knowledge", summary="지식 요약"),
        ]
    )
    orch = AgentOrchestrator(llm=llm, tools=_Registry(), max_steps=8, gateway=gateway)
    events = await _drain(orch, uuid4(), uuid4())
    assert llm.turns == 2
    assert gateway.applied.intent is Intent.KNOWLEDGE
    assert any(e.kind == "tool_started" for e in events)
    assert any(e.kind == "tool_finished" for e in events)


@pytest.mark.asyncio
async def test_secondary_intent_dedup_and_applicability():
    gateway = _FakeGateway(AnalysisInput(text="x", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=_ScriptedLLM(
            [_finalize_chunk(intent="todo", secondary_intents=["todo", "knowledge"])]
        ),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
    )
    await _drain(orch, uuid4(), uuid4())
    # primary(todo) 가 secondary 에서 제거됨
    assert gateway.applied.secondary_intents == (Intent.KNOWLEDGE,)
    assert gateway.applied.intent_applicability == {Intent.TODO: 0.9}


@pytest.mark.asyncio
async def test_max_steps_exhausted_raises_and_emits_failed():
    gateway = _FakeGateway(AnalysisInput(text=None, url="https://example.com", user_memo=None))
    orch = AgentOrchestrator(llm=_LoopingLLM(), tools=_Registry(), max_steps=3, gateway=gateway)
    events = []
    with pytest.raises(RuntimeError):
        async for ev in orch.run(uuid4(), uuid4()):
            events.append(ev)
    assert gateway.applied is None
    assert any(e.kind == "failed" for e in events)
