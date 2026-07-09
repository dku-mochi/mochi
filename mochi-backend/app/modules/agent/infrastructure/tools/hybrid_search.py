"""hybridSearch — 분석 중 사용자의 과거 기록을 능동 검색하는 어댑터 tool.

채팅 ``SearchItemsTool`` 을 분석 에이전트에 노출한다. 핵심: **저장 게이트가 아니라 분석 보강
신호**다 — 중복이어도 항상 저장한다(미션 "놓치기 쉬운 순간은 쉽게 남긴다"). 발견한 중복/연결/
일정충돌은 ``finalizeAnalysis`` summary 에 녹이거나 needs_review 로 물을 뿐, 저장을 막지 않는다.

owner_id 는 ``ToolContext`` 로 주입받아 cross-tenant 누설을 막는다(LLM args 가 아니라 orchestrator
가 현재 분석 중인 item 의 owner 를 건넨다). ``SearchItemsTool`` 은 conversations.application 팩토리로
받으므로 모듈 경계를 넘지 않는다 — 여기서 그 구체 타입을 import 하지 않고 ``.run(owner_id=, args=)``
만 호출한다(duck-typing).
"""

from typing import Any

from pydantic import BaseModel, Field

from app.modules.agent.domain.tools import ContextAwareTool, ToolContext, ToolName, ToolUsage


class HybridSearchInput(BaseModel):
    queries: list[str] = Field(default_factory=list)
    intent_type: str | None = None
    occurs_from: str | None = None
    occurs_to: str | None = None
    date_from: str | None = None
    date_to: str | None = None
    limit: int | None = None


class HybridSearchOutput(BaseModel):
    items: list[dict[str, Any]] = Field(default_factory=list)
    count: int = 0


class HybridSearchTool(ContextAwareTool[HybridSearchInput, HybridSearchOutput]):
    name = ToolName.HYBRID_SEARCH
    input_model = HybridSearchInput
    output_model = HybridSearchOutput

    def __init__(self, search_items: Any):
        # search_items = conversations.application.make_search_items_tool 의 반환(SearchItemsTool).
        # 모듈 경계상 구체 타입을 import 하지 않고 .run(owner_id=, args=) 만 호출한다(duck-typing).
        self._search = search_items

    async def run_with_context(
        self, payload: HybridSearchInput, *, context: ToolContext
    ) -> tuple[HybridSearchOutput, ToolUsage]:
        result = await self._search.run(owner_id=context.owner_id, args=payload.model_dump(exclude_none=True))
        raw = result.payload if isinstance(result.payload, dict) else {}
        items = raw.get("items", [])
        return HybridSearchOutput(items=items, count=len(items)), ToolUsage()
