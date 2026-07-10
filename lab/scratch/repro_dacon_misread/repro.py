"""문제 캡처(cb58f79f) '데이스쿨 할인 리턴즈' 오인 재현.

실제 AgentOrchestrator 를 stub gateway 로 돌린다 — prod DB 는 건드리지 않고
실제 Gemini(flash-lite) + 실제 tool registry(webFetch/findReferenceUrls/...)로
analyze 루프를 그대로 재실행한다. 입력은 DB 에 저장된 그 아이템의 원천 그대로:

  text="[출처앱: Safari]", url=dacon, user_memo=None, OCR=None, image=그 스크린샷(gs://)

실행: cd mochi-backend && .venv/bin/python ../lab/scratch/repro_dacon_misread/repro.py
"""

import asyncio
import sys
from uuid import uuid4

sys.path.insert(0, "/Users/jun/Downloads/mochi/mochi-backend")

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
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
            text="[출처앱: Safari]",
            url=DACON_URL,
            user_memo=None,
            analysis_ocr_text=None,
            images=((GS_URI, "image/jpeg"),),
        )

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.result = result

    async def index_embedding(self, **kw):
        pass

    async def list_recent_window(self, *, owner_id, limit):
        return []

    async def count_items(self, *, owner_id):
        return 0


async def run_once(label: str):
    settings = get_settings()
    tools = StaticToolRegistry(
        session_factory=None,  # hybridSearch 제외(DB 없음) — 나머지 tool 은 실제 등록
        voyage=None,
        tavily_api_key=settings.tavily_api_key,
    )
    gateway = StubGateway()
    orch = AgentOrchestrator(
        llm=GeminiAgentClient(),
        tools=tools,
        max_steps=settings.agent_max_steps,
        persistence=None,
        gateway=gateway,
        profile_store=None,
        embedder=None,
    )
    called = []
    print(f"\n========== RUN [{label}] ==========")
    print(f"model={settings.gemini_agent_model} location={settings.gemini_agent_location}")
    print(f"available tools: {[t.name.value for t in tools.all()]}")
    async for ev in orch.run(uuid4(), uuid4()):
        if ev.kind == "tool_started":
            called.append(ev.payload.get("name"))
            print(f"  -> TOOL CALL: {ev.payload.get('name')}")
        elif ev.kind == "failed":
            print(f"  !! FAILED: {ev.payload.get('message')}")
    r = gateway.result
    print(f"\n  tools actually called: {called or '(none)'}")
    if r is None:
        print("  (no result)")
        return
    print(f"  summary : {r.summary}")
    print(f"  category: {r.category}")
    print(f"  needs_review: {r.needs_review}")
    print(f"  intent_instances ({len(r.intent_instances)}):")
    for i in r.intent_instances:
        print(f"    - [{i.intent_type}] title={i.payload.title!r} label={i.label!r}")


async def main():
    # flash-lite 변동성 확인 위해 2회
    for n in range(2):
        await run_once(f"attempt-{n + 1}")


asyncio.run(main())
