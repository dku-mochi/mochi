"""ANN 가설 검증: 살아있던 '데이콘 경진대회' 전례가 컨텍스트에 들어갔다면 교정됐을까?

mode A(이미 측정): 컨텍스트 없음 → 1/6 데이스쿨
mode C(여기): 실제로 살아있던 '데이콘 경진대회' 전례 3줄 주입 → 데이스쿨율

C 가 0 에 가까우면, recency 대신 ANN 으로 그 데이콘 3개를 주입했어야 했다는 결론.

실행: cd mochi-backend && .venv/bin/python ../lab/scratch/repro_dacon_misread/probe4.py
"""

import asyncio
import sys
from uuid import uuid4

sys.path.insert(0, "/Users/jun/Downloads/mochi/mochi-backend")

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.profile import ProfileWindowItem  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402
from app.shared.intent import Intent  # noqa: E402

GS_URI = (
    "gs://mochi-captures-axial-device-460408-i9/captures/"
    "71503fa8-d478-4a2c-b2ac-3d29b0498ccd/"
    "507ee1f32d3b8f91048c4806641d2b17148f44152dd0e1bf6a99d0dc910e8322.jpg"
)
DACON_URL = "https://dacon.io/competitions/official/236693/overview/description"

# 실제로 그 시점 살아있던 데이콘 경진대회 전례(9393b19f / 39d0568f / 57fea09d 모양)
DACON_PRECEDENTS = [
    ProfileWindowItem(
        mochi_item_id=uuid4(),
        summary="참여 중인 데이콘 경진대회의 주요 제출 기한과 결과 발표 일정입니다.",
        title="데이콘 경진대회 예선 기획서 제출",
        category="커리어 개발",
        intent_types=(Intent.TODO, Intent.SCHEDULE),
        user_memo=None,
    ),
    ProfileWindowItem(
        mochi_item_id=uuid4(),
        summary="데이콘(DACON) 경진대회의 세부 일정입니다. 예선 기획서·산출물 제출 마감.",
        title="데이콘 경진대회 예선 산출물 제출",
        category="커리어 개발",
        intent_types=(Intent.TODO,),
        user_memo=None,
    ),
    ProfileWindowItem(
        mochi_item_id=uuid4(),
        summary="2026 AI·SW중심대학 디지털 경진대회(SW부문)의 예선 일정.",
        title="디지털 경진대회 예선 결과 발표",
        category="커리어 개발",
        intent_types=(Intent.SCHEDULE,),
        user_memo=None,
    ),
]


class StubGateway:
    def __init__(self, window):
        self.result = None
        self._window = window

    async def load_source(self, *, owner_id, mochi_item_id):
        return AnalysisInput(
            text="[출처앱: Safari]", url=DACON_URL, user_memo=None,
            analysis_ocr_text=None, images=((GS_URI, "image/jpeg"),),
        )

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.result = result

    async def index_embedding(self, **kw): ...
    async def list_recent_window(self, *, owner_id, limit):
        return list(self._window)
    async def count_items(self, *, owner_id): return 0


def has_ds(s) -> bool:
    return "데이스쿨" in str(s)


async def one(window):
    settings = get_settings()
    reg = StaticToolRegistry(session_factory=None, voyage=None, tavily_api_key=settings.tavily_api_key)
    gateway = StubGateway(window)
    orch = AgentOrchestrator(
        llm=GeminiAgentClient(), tools=reg, max_steps=settings.agent_max_steps,
        persistence=None, gateway=gateway, profile_store=None, embedder=None,
    )
    async for _ in orch.run(uuid4(), uuid4()):
        pass
    r = gateway.result
    titles = [i.payload.title or "" for i in r.intent_instances] if r else []
    return has_ds(" ".join(titles)), (titles[0] if titles else None)


async def main():
    N = 6
    ds = 0
    print(f"\n===== mode C: 데이콘 경진대회 전례 3줄 주입 ({N}회) =====")
    for i in range(N):
        bad, t0 = await one(DACON_PRECEDENTS)
        ds += bad
        print(f"  {i + 1}: {'❌데이스쿨' if bad else '✅데이콘'}  | {t0!r}")
    print(f"\n========== 결론 ==========")
    print(f"  A 컨텍스트없음(앞서) : 1/6 데이스쿨")
    print(f"  C 데이콘전례 주입    : {ds}/{N} 데이스쿨")


asyncio.run(main())
