"""Agent loop (orchestrator ANALYZED) 단위 테스트 — FakeLLM + fake gateway.

실제 Vertex 호출 없이 루프 제어만 검증:
- no-URL 단일 turn finalize → write-back
- platformContext turn → 되먹임 → finalize
- webFetch turn → 되먹임 → finalize
- 다중 instance 보존 (dedup/위계 없음)
- max_steps 소진 → graceful fail (failed 이벤트 + raise, write-back 없음)
"""

from datetime import UTC, datetime
from types import SimpleNamespace
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
from app.modules.agent.domain.tools import ToolContext, ToolName, ToolUsage
from app.modules.agent.infrastructure.tools.hybrid_search import HybridSearchInput, HybridSearchTool
from app.modules.agent.infrastructure.tools.web_search import WebSearchAgentTool, WebSearchInput
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
        yield LLMResponseChunk(tool_to_call=ToolName.WEB_FETCH, tool_arguments={"url": "https://example.com"})


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
    def __init__(self, source: AnalysisInput, category_vocabulary: list[str] | None = None):
        self._source = source
        self._category_vocabulary = category_vocabulary or []
        self.applied = None
        self.indexed = None
        self.category_vocabulary_calls = []

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

    async def list_category_vocabulary(self, *, owner_id, limit):
        self.category_vocabulary_calls.append((owner_id, limit))
        return self._category_vocabulary[:limit]

    async def count_items(self, *, owner_id):
        return 0


class _FakeEmbedder:
    model_version = "voyage-4-large@1024"

    def __init__(self):
        self.calls = []

    async def embed_documents(self, texts):
        self.calls.append(list(texts))
        return [[0.1] * 4 for _ in texts]


class _ExplodingEmbedder:
    model_version = "voyage-4-large@1024"

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
    gateway = _FakeGateway(AnalysisInput(text="다음 주까지 발표 대본 수정하기", url=None, user_memo=None))
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
async def test_lifetime_category_vocabulary_is_injected_as_weak_context():
    owner_id = uuid4()
    gateway = _FakeGateway(
        AnalysisInput(text="ETF 공부 자료", url=None, user_memo=None),
        category_vocabulary=["투자", "학업", "쇼핑"],
    )
    llm = _ScriptedLLM([_finalize_chunk(intent="knowledge")])
    orch = AgentOrchestrator(
        llm=llm,
        tools=_Registry(),
        max_steps=8,
        gateway=gateway,
    )

    await _drain(orch, uuid4(), owner_id)

    prompt = llm.calls[0]["user_parts"][0]["text"]
    assert "# 기존 카테고리 어휘 (전체 기록)" in prompt
    assert "투자, 학업, 쇼핑" in prompt
    assert "약한 힌트" in prompt
    assert gateway.category_vocabulary_calls == [(owner_id, 50)]


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
    assert gateway.indexed["model_version"] == "voyage-4-large@1024"


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
        model_version = "voyage-4-large@1024"

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
    gateway = _FakeGateway(AnalysisInput(text=None, url="https://youtu.be/abc", user_memo=None))
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
    assert any(e.kind == "tool_started" and e.payload["name"] == "platformContext" for e in events)


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


@pytest.mark.asyncio
async def test_reanalysis_hint_forces_needs_review_false():
    # 재분석(사용자 의도 확정, hint 필수)은 LLM 이 needs_review=true 를 내도 false 로 강제하고
    # review_options 를 비운다 — "확정했는데 모찌가 되묻는" 미션 위반 방지(DOMAIN_DESIGN §6.3).
    gateway = _FakeGateway(AnalysisInput(text="영수증", url=None, user_memo=None))
    chunk = _finalize_chunk(
        needs_review=True,
        review_options=[{"intent_type": "todo", "label": "할 일", "reasoning": "?"}],
    )
    orch = AgentOrchestrator(llm=_ScriptedLLM([chunk]), tools=_Registry(), max_steps=8, gateway=gateway)
    async for _ev in orch.run(uuid4(), uuid4(), reanalysis_hint="todo 로 분류해줘"):
        pass
    assert gateway.applied.needs_review is False
    assert gateway.applied.review_options == ()


@pytest.mark.asyncio
async def test_first_analysis_keeps_llm_needs_review():
    # 첫 분석(hint 없음)은 LLM holistic 판단을 그대로 존중 — needs_review=true 유지.
    gateway = _FakeGateway(AnalysisInput(text="애매한 캡처", url=None, user_memo=None))
    chunk = _finalize_chunk(
        needs_review=True,
        review_options=[{"intent_type": "todo", "label": "할 일", "reasoning": "?"}],
    )
    orch = AgentOrchestrator(llm=_ScriptedLLM([chunk]), tools=_Registry(), max_steps=8, gateway=gateway)
    await _drain(orch, uuid4(), uuid4())
    assert gateway.applied.needs_review is True
    assert len(gateway.applied.review_options) == 1


# ---------- 검색 어댑터 (hybridSearch / webSearch) ----------


class _FakeChatSearch:
    """SearchItemsTool/WebSearchTool duck-type — owner_id·args 를 캡처한다."""

    def __init__(self, payload: dict):
        self._payload = payload
        self.owner_id = None
        self.args: dict | None = None

    async def run(self, *, owner_id, args):
        self.owner_id = owner_id
        self.args = args
        return SimpleNamespace(payload=self._payload)


@pytest.mark.asyncio
async def test_hybrid_search_tool_binds_owner_and_unwraps_items():
    search = _FakeChatSearch({"items": [{"id": "1"}, {"id": "2"}], "count": 2})
    owner = uuid4()
    out, _ = await HybridSearchTool(search).run_with_context(
        HybridSearchInput(queries=["민수"], intent_type="schedule"),
        context=ToolContext(owner_id=owner, mochi_item_id=uuid4()),
    )
    assert search.owner_id == owner  # owner 는 LLM args 가 아니라 context 에서 주입
    assert search.args["queries"] == ["민수"]
    assert search.args["intent_type"] == "schedule"
    assert "limit" not in search.args  # exclude_none — 미지정 필드는 빠진다
    assert out.count == 2


@pytest.mark.asyncio
async def test_web_search_tool_unwraps_results():
    search = _FakeChatSearch({"results": [{"url": "https://a"}], "count": 1})
    out, _ = await WebSearchAgentTool(search).run_with_context(
        WebSearchInput(queries=["q1", "q2"]),
        context=ToolContext(owner_id=uuid4(), mochi_item_id=uuid4()),
    )
    assert search.args["queries"] == ["q1", "q2"]
    assert out.count == 1


class _ContextRegistry:
    def __init__(self, tool):
        self._t = {tool.name: tool}

    def get(self, name):
        return self._t[name]

    def all(self):
        return list(self._t.values())


@pytest.mark.asyncio
async def test_orchestrator_injects_owner_into_context_aware_tool():
    # owner_id 는 LLM args 가 아니라 orchestrator(현재 분석 owner)가 주입한다 — cross-tenant 방어.
    owner = uuid4()
    search = _FakeChatSearch({"items": []})
    llm = _ScriptedLLM(
        [
            LLMResponseChunk(tool_to_call=ToolName.HYBRID_SEARCH, tool_arguments={"queries": ["민수"]}),
            _finalize_chunk(),
        ]
    )
    gateway = _FakeGateway(AnalysisInput(text="t", url=None, user_memo=None))
    orch = AgentOrchestrator(
        llm=llm, tools=_ContextRegistry(HybridSearchTool(search)), max_steps=8, gateway=gateway
    )
    await _drain(orch, uuid4(), owner)
    assert search.owner_id == owner
    assert search.args["queries"] == ["민수"]
