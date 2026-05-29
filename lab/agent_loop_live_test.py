"""라이브 검증 — (A) 이미지 의도 분류기 on lab 스크린샷, (B) 새 agent loop on text/URL.

실행: GOOGLE_CLOUD_PROJECT=<proj> uv run python ../lab/agent_loop_live_test.py
(mochi-backend 디렉토리에서, ADC 필요)

A: 기존 VertexAIGeminiClassifier (back-tap 이미지 경로) — 파일명 힌트 vs 예측 비교.
B: 이번 세션 신규 GeminiAgentClient + AgentOrchestrator (text/URL) — fake in-memory gateway 로
   write-back 까지 end-to-end. 실제 Gemini function-calling 루프가 finalizeAnalysis 를 저술하는지.
"""

import asyncio
from pathlib import Path
from uuid import uuid4

from app.modules.agent.application.orchestrator import AgentOrchestrator
from app.modules.agent.domain.analysis import AnalysisResult
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient
from app.modules.agent.infrastructure.registry import StaticToolRegistry
from app.modules.mochi_items.infrastructure.gemini_classifier import VertexAIGeminiClassifier

SHOT_DIR = Path(__file__).parent / "data" / "screenshot"
IMAGES = [
    "마우스 살까 말까 고민중.PNG",
    "이뻐서 구매고민중 기록.PNG",
    "나중에 공부해보려고 저장.png",
    "아키텍쳐 참고 해보려고.PNG",
]


class _FakeGateway:
    """DB 없이 agent loop 를 돌리기 위한 in-memory gateway."""

    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied: AnalysisResult | None = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def list_recent_window(self, *, owner_id, limit):
        return []

    async def count_items(self, *, owner_id):
        return 0


async def run_classifier() -> None:
    print("\n" + "=" * 70)
    print("A. 이미지 의도 분류기 (VertexAIGeminiClassifier, back-tap 경로)")
    print("=" * 70)
    clf = VertexAIGeminiClassifier()
    for name in IMAGES:
        path = SHOT_DIR / name
        print(f"\n📷 {name}", flush=True)
        if not path.exists():
            print("   [skip] 파일 없음")
            continue
        try:
            result = await clf.classify(image=path.read_bytes(), mime="image/png")
            for c in result.candidates:
                print(f"   - {c.label:<12} intent={c.intent.value:<9} "
                      f"applicability={c.applicability:.2f}  · {c.reasoning}")
        except Exception as exc:  # noqa: BLE001
            print(f"   [ERROR] {type(exc).__name__}: {str(exc)[:300]}")


async def run_agent_loop() -> None:
    print("\n" + "=" * 70)
    print("B. 신규 agent loop (GeminiAgentClient + AgentOrchestrator, text/URL)")
    print("=" * 70)
    llm = GeminiAgentClient()
    tools = StaticToolRegistry()

    cases = [
        ("text", AnalysisInput(
            text="다음 주 금요일 23:59까지 운영체제 과제(스케줄러 구현) 제출하기",
            url=None, user_memo=None)),
        ("text", AnalysisInput(
            text="LangChain 에서 ReAct 에이전트가 도구를 선택하는 구조 설명 — Thought/Action/Observation 루프",
            url=None, user_memo="나중에 발표 준비할 때 참고")),
        ("url", AnalysisInput(
            text=None, url="https://ko.wikipedia.org/wiki/대규모_언어_모델", user_memo=None)),
    ]

    for kind, source in cases:
        label = source.text or source.url or ""
        print(f"\n📝 [{kind}] {label[:60]}", flush=True)
        try:
            gateway = _FakeGateway(source)
            orch = AgentOrchestrator(llm=llm, tools=tools, max_steps=8, gateway=gateway)
            events = []
            async for ev in orch.run(uuid4(), uuid4()):
                events.append(ev.kind)
            a = gateway.applied
            print(f"   events: {events}")
            if a:
                print(f"   → intent={a.intent.value}  secondary={[i.value for i in a.secondary_intents]}"
                      f"  confidence={a.confidence:.2f}  importance={a.importance}")
                print(f"   → summary: {a.summary}")
                if a.entities:
                    print(f"   → entities: {[(e.kind, e.value) for e in a.entities]}")
        except Exception as exc:  # noqa: BLE001
            print(f"   [ERROR] {type(exc).__name__}: {str(exc)[:300]}")


async def main() -> None:
    await run_classifier()
    await run_agent_loop()


if __name__ == "__main__":
    asyncio.run(main())
