"""Agent loop (orchestrator ANALYZED) 단위 테스트 — FakeLLM + fake gateway.

실제 Vertex 호출 없이 루프 제어만 검증:
- no-URL 단일 turn finalize → write-back
- platformContext turn → 되먹임 → finalize
- webFetch turn → 되먹임 → finalize
- 다중 instance 보존 (dedup/위계 없음)
- max_steps 소진 → graceful fail (failed 이벤트 + raise, write-back 없음)
"""

from datetime import UTC, datetime
from uuid import uuid4

import pytest
from pydantic import BaseModel

from app.modules.agent.application.orchestrator import (
    AgentOrchestrator,
    _initial_user_text,
    _korea_time_context,
)
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.agent.domain.ports import LLMResponseChunk
from app.modules.agent.domain.tools import ToolName, ToolUsage
from app.shared.intent import Intent


class _ScriptedLLM:
    """미리 정한 chunk 들을 turn 마다 하나씩 흘린다."""

    def __init__(self, chunks: list[LLMResponseChunk]):
        self._chunks = chunks
        self.turns = 0
        self.calls = []

    async def stream(self, **kwargs):
        self.calls.append(kwargs)
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


class _FakePlatformContextTool:
    name = ToolName.PLATFORM_CONTEXT
    input_model = _UrlInput

    async def run(self, payload):
        class _Out(BaseModel):
            text: str = "platform context text"
            final_url: str = "https://www.youtube.com/watch?v=abc"
            platform: str = "youtube"

        return _Out(), ToolUsage(tokens_in=1, tokens_out=1, latency_ms=1)


class _Registry:
    def __init__(self):
        self._t = {
            ToolName.PLATFORM_CONTEXT: _FakePlatformContextTool(),
            ToolName.WEB_FETCH: _FakeWebFetchTool(),
        }

    def get(self, name):
        return self._t[name]

    def all(self):
        return list(self._t.values())


class _FakeGateway:
    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied = None
        self.indexed = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def index_embedding(self, *, owner_id, mochi_item_id, chunk_text, embedding, model_version):
        self.indexed = {
            "chunk_text": chunk_text,
            "embedding": embedding,
            "model_version": model_version,
        }

    async def list_recent_window(self, *, owner_id, limit):
        return []

    async def count_items(self, *, owner_id):
        return 0


class _FakeEmbedder:
    model_version = "voyage-3-large@1024"

    def __init__(self):
        self.calls = []

    async def embed_documents(self, texts):
        self.calls.append(list(texts))
        return [[0.1] * 4 for _ in texts]


class _ExplodingEmbedder:
    model_version = "voyage-3-large@1024"

    async def embed_documents(self, texts):
        raise RuntimeError("voyage down")


def _finalize_chunk(
    intent="todo", summary="할 일 요약", *, instances=None, needs_review=False, review_options=None
) -> LLMResponseChunk:
    """기본은 단일 instance(곧 active). instances 로 multi-instance 주입 가능."""
    if instances is None:
        instances = [{"intent_type": intent, "payload": {}, "label": "후보", "reasoning": "-"}]
    payload = {
        "summary": summary,
        "needs_review": needs_review,
        "intent_instances": instances,
        "review_options": review_options or [],
        "model_version": "test",
    }
    return LLMResponseChunk(final_payload=payload)


async def _drain(orch, item_id, owner_id):
    events = []
    async for ev in orch.run(item_id, owner_id):
        events.append(ev)
    return events


def test_korea_time_context_uses_seoul_timezone():
    now = datetime(2026, 5, 30, 12, 34, 56, tzinfo=UTC)
    text = _korea_time_context(now)
    assert "현재 기준시각(Asia/Seoul): 2026-05-30T21:34:56+09:00" in text
    assert "상대 날짜" in text


def test_initial_user_text_includes_time_and_image_instruction():
    text = _initial_user_text(
        AnalysisInput(
            text=None,
            url=None,
            user_memo="다음 주에 확인",
            images=(("gs://bucket/object.jpg", "image/jpeg"),),
        )
    )
    assert "# 시간 컨텍스트" in text
    assert "사용자 메모: 다음 주에 확인" in text
    assert "첨부된 스크린샷/이미지를 함께 분석하세요." in text


@pytest.mark.asyncio
async def test_no_url_single_turn_finalize_writes_back():
    gateway = _FakeGateway(
        AnalysisInput(text="다음 주까지 발표 대본 수정하기", url=None, user_memo=None)
    )
    llm = _ScriptedLLM([_finalize_chunk(intent="todo")])
    orch = AgentOrchestrator(
        llm=llm,
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
    )
    events = await _drain(orch, uuid4(), uuid4())
    assert gateway.applied is not None
    assert gateway.applied.intent_instances[0].intent_type is Intent.TODO
    assert gateway.applied.summary == "할 일 요약"
    assert any(e.kind == "final" for e in events)
    assert "# 시간 컨텍스트" in llm.calls[0]["user_parts"][0]["text"]


@pytest.mark.asyncio
async def test_indexed_node_embeds_summary_and_labels():
    # INDEXED — 임베딩 input 은 summary + intent labels (rag-rerank-eval 고정 조건).
    gateway = _FakeGateway(AnalysisInput(text="t", url=None, user_memo=None))
    embedder = _FakeEmbedder()
    orch = AgentOrchestrator(
        llm=_ScriptedLLM([_finalize_chunk()]),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
        embedder=embedder,
    )
    await _drain(orch, uuid4(), uuid4())
    assert embedder.calls == [["할 일 요약 후보"]]
    assert gateway.indexed["chunk_text"] == "할 일 요약 후보"
    assert gateway.indexed["embedding"] == [0.1] * 4
    assert gateway.indexed["model_version"] == "voyage-3-large@1024"


@pytest.mark.asyncio
async def test_indexed_failure_is_best_effort_and_run_succeeds():
    # 색인 실패가 run 을 죽이면 outbox 재시도 = Gemini 재분석 비용 — 분석은 이미 영속됐다.
    gateway = _FakeGateway(AnalysisInput(text="t", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=_ScriptedLLM([_finalize_chunk()]),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
        embedder=_ExplodingEmbedder(),
    )
    events = await _drain(orch, uuid4(), uuid4())
    assert gateway.applied is not None
    assert gateway.indexed is None
    assert any(e.kind == "final" for e in events)


@pytest.mark.asyncio
async def test_indexed_timeout_is_best_effort(monkeypatch):
    # 임베딩이 INDEXED 자체 상한을 넘으면 — 워커 전체 예산(120s)을 침범해 run 이
    # CancelledError 로 죽는 대신 — 색인만 포기하고 run 은 완주한다 (리뷰 P1).
    import asyncio

    import app.modules.agent.application.orchestrator as orch_mod

    monkeypatch.setattr(orch_mod, "_INDEX_EMBED_TIMEOUT_SECONDS", 0.01)

    class _SlowEmbedder:
        model_version = "voyage-3-large@1024"

        async def embed_documents(self, texts):
            await asyncio.sleep(0.2)
            return [[0.1] * 4 for _ in texts]

    gateway = _FakeGateway(AnalysisInput(text="t", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=_ScriptedLLM([_finalize_chunk()]),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
        embedder=_SlowEmbedder(),
    )
    events = await _drain(orch, uuid4(), uuid4())
    assert gateway.applied is not None
    assert gateway.indexed is None
    assert any(e.kind == "final" for e in events)


@pytest.mark.asyncio
async def test_without_embedder_indexing_is_skipped():
    gateway = _FakeGateway(AnalysisInput(text="t", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=_ScriptedLLM([_finalize_chunk()]), tools=_Registry(), max_steps=8, gateway=gateway
    )
    events = await _drain(orch, uuid4(), uuid4())
    assert gateway.indexed is None
    assert any(e.kind == "final" for e in events)


@pytest.mark.asyncio
async def test_platform_context_then_finalize():
    gateway = _FakeGateway(
        AnalysisInput(text=None, url="https://youtu.be/abc", user_memo=None)
    )
    llm = _ScriptedLLM(
        [
            LLMResponseChunk(
                tool_to_call=ToolName.PLATFORM_CONTEXT,
                tool_arguments={"url": "https://youtu.be/abc", "platform": "youtube"},
            ),
            _finalize_chunk(intent="knowledge", summary="유튜브 지식 요약"),
        ]
    )
    orch = AgentOrchestrator(llm=llm, tools=_Registry(), max_steps=8, gateway=gateway)
    events = await _drain(orch, uuid4(), uuid4())
    assert llm.turns == 2
    assert gateway.applied.intent_instances[0].intent_type is Intent.KNOWLEDGE
    assert any(
        e.kind == "tool_started" and e.payload["name"] == "platformContext"
        for e in events
    )


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
    assert gateway.applied.intent_instances[0].intent_type is Intent.KNOWLEDGE
    assert any(e.kind == "tool_started" for e in events)
    assert any(e.kind == "tool_finished" for e in events)


@pytest.mark.asyncio
async def test_multiple_instances_preserved_without_dedup():
    gateway = _FakeGateway(AnalysisInput(text="x", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=_ScriptedLLM(
            [
                _finalize_chunk(
                    instances=[
                        {"intent_type": "todo", "payload": {}, "label": "a", "reasoning": "-"},
                        {"intent_type": "todo", "payload": {}, "label": "b", "reasoning": "-"},
                        {"intent_type": "knowledge", "payload": {}, "label": "c", "reasoning": "-"},
                    ]
                )
            ]
        ),
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
    )
    await _drain(orch, uuid4(), uuid4())
    # 같은 type 다중 instance 가 그대로 보존된다 — dedup/위계 폐기(2026-06-04).
    types = [i.intent_type for i in gateway.applied.intent_instances]
    assert types == [Intent.TODO, Intent.TODO, Intent.KNOWLEDGE]
    assert gateway.applied.intent_instances[0].label == "a"
    assert gateway.applied.needs_review is False


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
