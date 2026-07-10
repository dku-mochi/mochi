"""사용자 가설 검증: '최근 기록 컨텍스트'에 데이스쿨 전례가 있으면 전염되나?

mode A: recent_context 없음 (baseline) — 31d981bf 분석의 실제 상황(전례 삭제됨)
mode B: recent_context 에 '데이스쿨 할인 리턴즈' 전례 1줄 주입 (전례를 안 지웠을 때)

전염이 실재하면 B 의 '데이스쿨' 비율이 A 보다 확연히 높아야 한다.

실행: cd mochi-backend && .venv/bin/python ../lab/scratch/repro_dacon_misread/probe3.py
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

# 삭제 전이었다면 컨텍스트에 들어갔을 cb58f79f 전례 (실제 그 아이템 모양)
DS_PRECEDENT = ProfileWindowItem(
    mochi_item_id=uuid4(),
    summary="'데이스쿨 할인 리턴즈' 대회 참여를 위한 예선 시작부터 결과 발표까지의 주요 일정 및 마감 기한을 관리합니다.",
    title="데이스쿨 할인 리턴즈 예선 시작",
    category="커리어 개발",
    intent_types=(Intent.SCHEDULE, Intent.TODO),
    user_memo=None,
)


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


async def run_mode(label, window, n):
    ds = 0
    print(f"\n===== {label} ({n}회) =====")
    for i in range(n):
        bad, t0 = await one(window)
        ds += bad
        print(f"  {i + 1}: {'❌데이스쿨' if bad else '✅데이콘'}  | {t0!r}")
    print(f"  >>> {ds}/{n} 데이스쿨")
    return ds, n


async def main():
    N = 6
    a = await run_mode("mode A: 컨텍스트 없음 (전례 삭제됨 = 실제 상황)", [], N)
    b = await run_mode("mode B: 데이스쿨 전례 주입 (전례 안 지웠을 때)", [DS_PRECEDENT], N)
    print(f"\n========== 결론 ==========")
    print(f"  A 컨텍스트없음 : {a[0]}/{a[1]} 데이스쿨")
    print(f"  B 전례주입     : {b[0]}/{b[1]} 데이스쿨")


asyncio.run(main())
