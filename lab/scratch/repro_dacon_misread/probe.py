"""원인 가르기: 이미지 salience vs tool grounding vs flash-lite 변동성.

1) webFetch 가 dacon 페이지에서 실제 대회명을 얻을 수 있나? (SPA 여부)
2) tool 없이 순수 이미지만 볼 때 무엇으로 판단하나 (광고 배너 salience baseline)
3) tool 전체일 때 (현재 prod 구성) — N회 반복해 '데이스쿨' 재현율

실행: cd mochi-backend && .venv/bin/python ../lab/scratch/repro_dacon_misread/probe.py
"""

import asyncio
import sys
from uuid import uuid4

sys.path.insert(0, "/Users/jun/Downloads/mochi/mochi-backend")

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.ports import ToolRegistry  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402
from app.modules.agent.infrastructure.tools.web_fetch import WebFetchTool  # noqa: E402

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


class EmptyRegistry(ToolRegistry):
    """finalizeAnalysis 만 — 순수 멀티모달 (능동 tool 없음)."""
    def get(self, name): raise KeyError(name)
    def all(self): return []


def classify(titles: list[str]) -> str:
    blob = " ".join(titles)
    if "데이스쿨" in blob:
        return "WRONG(데이스쿨)"
    if "데이콘" in blob or "데이터 분석" in blob:
        return "OK(데이콘)"
    return "OTHER"


async def probe_webfetch():
    print("\n===== (1) webFetch: dacon 페이지에서 무엇을 읽는가 =====")
    tool = WebFetchTool()
    try:
        out, _ = await tool.run(tool.input_model.model_validate({"url": DACON_URL}))
        body = out.model_dump()
        txt = str(body.get("text") or "")
        print(f"  fetched len={len(txt)}")
        print(f"  '데이스쿨' in page: {'데이스쿨' in txt} | '데이콘'/'dacon': {('데이콘' in txt) or ('acon' in txt)}")
        print(f"  '경진대회' in page: {'경진대회' in txt} | '236693': {'236693' in txt}")
        print(f"  head: {txt[:300]!r}")
    except Exception as exc:  # noqa: BLE001
        print(f"  webFetch failed: {exc}")


async def run_once(registry, label):
    settings = get_settings()
    gateway = StubGateway()
    orch = AgentOrchestrator(
        llm=GeminiAgentClient(), tools=registry, max_steps=settings.agent_max_steps,
        persistence=None, gateway=gateway, profile_store=None, embedder=None,
    )
    called = []
    async for ev in orch.run(uuid4(), uuid4()):
        if ev.kind == "tool_started":
            called.append(ev.payload.get("name"))
    r = gateway.result
    titles = [i.payload.title or "" for i in r.intent_instances] if r else []
    verdict = classify(titles)
    cat = r.category if r else "?"
    print(f"  [{label}] {verdict:16} cat={cat!r:22} tools={called} | titles[0]={titles[0] if titles else None!r}")
    return verdict


async def main():
    settings = get_settings()
    await probe_webfetch()

    N = 5
    full = StaticToolRegistry(session_factory=None, voyage=None, tavily_api_key=settings.tavily_api_key)
    empty = EmptyRegistry()

    print(f"\n===== (2) 순수 이미지(tool 없음) — 광고 배너 salience baseline, {N}회 =====")
    a = [await run_once(empty, f"no-tools {i + 1}") for i in range(N)]
    print(f"\n===== (3) tool 전체(prod 구성), {N}회 =====")
    b = [await run_once(full, f"full {i + 1}") for i in range(N)]

    def tally(rs):
        from collections import Counter
        return dict(Counter(rs))

    print("\n===== 집계 =====")
    print(f"  순수 이미지   : {tally(a)}")
    print(f"  tool 전체     : {tally(b)}")


asyncio.run(main())
