"""라이브 검증 — agent loop on text/URL (GeminiAgentClient + AgentOrchestrator).

실행: GOOGLE_CLOUD_PROJECT=<proj> uv run python ../lab/agent_loop_live_test.py
(mochi-backend 디렉토리에서, ADC 필요)

fake in-memory gateway 로 write-back 까지 end-to-end.
실제 Gemini function-calling 루프가 finalizeAnalysis 를 저술하는지 확인.
"""

import asyncio
from uuid import uuid4

from app.modules.agent.application.orchestrator import AgentOrchestrator
from app.modules.agent.domain.analysis import AnalysisResult
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.agent.domain.profile import ProfileWindowItem
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient
from app.modules.agent.infrastructure.registry import StaticToolRegistry


class _FakeGateway:
    """DB 없이 agent loop 를 돌리기 위한 in-memory gateway."""

    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied: AnalysisResult | None = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def list_recent_window(self, *, owner_id, limit) -> list[ProfileWindowItem]:
        return []

    async def count_items(self, *, owner_id):
        return 0


async def run_agent_loop() -> None:
    print("\n" + "=" * 70)
    print("agent loop (GeminiAgentClient + AgentOrchestrator, text/URL)")
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
                instances = [inst.intent_type.value for inst in a.intent_instances]
                print(f"   → instances={instances}  needs_review={a.needs_review}  importance={a.importance}")
                print(f"   → summary: {a.summary}")
                if a.entities:
                    print(f"   → entities: {[(e.kind, e.value) for e in a.entities]}")
        except Exception as exc:  # noqa: BLE001
            print(f"   [ERROR] {type(exc).__name__}: {str(exc)[:300]}")


async def run_one_url(url: str) -> None:
    print("\n" + "=" * 70)
    print(f"agent loop on URL: {url}")
    print("=" * 70)
    llm = GeminiAgentClient()
    tools = StaticToolRegistry()
    gateway = _FakeGateway(AnalysisInput(text=None, url=url, user_memo=None))
    orch = AgentOrchestrator(llm=llm, tools=tools, max_steps=8, gateway=gateway)
    events = []
    async for ev in orch.run(uuid4(), uuid4()):
        events.append(ev.kind)
    a = gateway.applied
    print(f"events: {events}")
    if a:
        instances = [inst.intent_type.value for inst in a.intent_instances]
        print(f"→ instances={instances}  needs_review={a.needs_review}  importance={a.importance}")
        print(f"→ summary: {a.summary}")
        if a.entities:
            print(f"→ entities: {[(e.kind, e.value) for e in a.entities]}")


async def main() -> None:
    import sys
    if len(sys.argv) > 1:
        for url in sys.argv[1:]:
            await run_one_url(url)
        return
    await run_agent_loop()


if __name__ == "__main__":
    asyncio.run(main())
