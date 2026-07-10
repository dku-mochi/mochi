"""findReferenceUrls 가 '데이스쿨' 을 어디서 주입하는지 확정.

메인이 넘기는 queries 와 tool 이 모델에 되먹이는 ranked_urls.title / reference_entities /
comment 를 그대로 캡처해, 최종 제목과 대조한다. '데이스쿨' 이
  - 모델이 넘긴 queries 에서 오나? (이미지 광고배너 → query)
  - 검색 결과 title/description 에서 오나? (네이버/Tavily 가 주입)
를 가른다.

실행: cd mochi-backend && .venv/bin/python ../lab/scratch/repro_dacon_misread/probe2.py
"""

import asyncio
import sys
from uuid import uuid4

sys.path.insert(0, "/Users/jun/Downloads/mochi/mochi-backend")

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.tools import ToolName  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402

GS_URI = (
    "gs://mochi-captures-axial-device-460408-i9/captures/"
    "71503fa8-d478-4a2c-b2ac-3d29b0498ccd/"
    "507ee1f32d3b8f91048c4806641d2b17148f44152dd0e1bf6a99d0dc910e8322.jpg"
)
DACON_URL = "https://dacon.io/competitions/official/236693/overview/description"


class StubGateway:
    def __init__(self):
        self.result = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return AnalysisInput(
            text="[출처앱: Safari]", url=DACON_URL, user_memo=None,
            analysis_ocr_text=None, images=((GS_URI, "image/jpeg"),),
        )

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.result = result

    async def index_embedding(self, **kw): ...
    async def list_recent_window(self, *, owner_id, limit): return []
    async def count_items(self, *, owner_id): return 0


class SpyResourceFinder:
    """ResourceFinderTool 래퍼 — in/out 을 기록(ContextAwareTool 아님 → run(payload) 경로)."""

    def __init__(self, inner):
        self.inner = inner
        self.name = inner.name
        self.input_model = inner.input_model
        self.output_model = inner.output_model
        self.calls = []

    async def run(self, payload):
        out, usage = await self.inner.run(payload)
        self.calls.append(
            {
                "queries": list(payload.queries),
                "category": payload.category,
                "useful": out.useful,
                "comment": out.comment,
                "result_titles": [r.title for r in out.ranked_urls],
                "refs": out.reference_entities,
            }
        )
        return out, usage


def has_ds(s) -> bool:
    return "데이스쿨" in str(s)


async def one(idx):
    settings = get_settings()
    reg = StaticToolRegistry(session_factory=None, voyage=None, tavily_api_key=settings.tavily_api_key)
    spy = SpyResourceFinder(reg.get(ToolName.RESOURCE_FINDER))
    reg._tools[ToolName.RESOURCE_FINDER] = spy
    gateway = StubGateway()
    orch = AgentOrchestrator(
        llm=GeminiAgentClient(), tools=reg, max_steps=settings.agent_max_steps,
        persistence=None, gateway=gateway, profile_store=None, embedder=None,
    )
    async for _ in orch.run(uuid4(), uuid4()):
        pass
    r = gateway.result
    titles = [i.payload.title or "" for i in r.intent_instances] if r else []
    final_ds = has_ds(" ".join(titles))

    print(f"\n--- run {idx} --- 최종제목 {'❌데이스쿨' if final_ds else '✅데이콘'} (cat={r.category if r else '?'})")
    for c in spy.calls:
        q_ds = has_ds(c["queries"])
        res_ds = has_ds(c["result_titles"]) or has_ds(c["refs"])
        cm_ds = has_ds(c["comment"])
        print(f"  queries={c['queries']}  [데이스쿨 in query? {q_ds}]")
        print(f"  result_titles={c['result_titles'][:4]}  [데이스쿨 in 검색결과? {res_ds}]")
        print(f"  comment={c['comment']!r}  [데이스쿨 in comment? {cm_ds}]")
    print(f"  → 최종제목[0]: {titles[0] if titles else None!r}")
    return final_ds


async def main():
    n = 0
    ds = 0
    for i in range(6):
        if await one(i + 1):
            ds += 1
        n += 1
    print(f"\n===== {ds}/{n} run 이 최종제목에 '데이스쿨' =====")


asyncio.run(main())
