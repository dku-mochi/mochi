"""webSearch — 분석 중 외부 사실을 그라운딩하는 어댑터 tool (KNOWLEDGE 보강).

채팅 ``WebSearchTool``(Tavily)을 분석 에이전트에 노출한다. 캡처가 가리키는 개념·사건·인물이
"무엇인지" 외부 사실이 분석을 바꿀 때만 쓴다(findReferenceUrls 가 커머스·장소 특화인 빈자리).

**데이터 경계**: 기록 원문이나 사용자를 식별할 수 있는 문구를 외부 쿼리에 반출 금지 — generic
public 쿼리로 바꿔 보낸다(코드가 아니라 system prompt 행동규칙이 가드, 채팅 선례 동형). 웹검색은
owner 무관이나 채팅 tool 시그니처 통일성상 ToolContext 의 owner_id 를 그대로 넘긴다(미사용).
"""

from typing import Any

from pydantic import BaseModel, Field

from app.modules.agent.domain.tools import ContextAwareTool, ToolContext, ToolName, ToolUsage


class WebSearchInput(BaseModel):
    queries: list[str] = Field(default_factory=list)


class WebSearchOutput(BaseModel):
    results: list[dict[str, Any]] = Field(default_factory=list)
    count: int = 0


class WebSearchAgentTool(ContextAwareTool[WebSearchInput, WebSearchOutput]):
    name = ToolName.WEB_SEARCH
    input_model = WebSearchInput
    output_model = WebSearchOutput

    def __init__(self, web_search: Any):
        # web_search = conversations.application.make_web_search_tool 의 반환(WebSearchTool).
        # duck-typing — 모듈 경계상 구체 타입을 import 하지 않고 .run(owner_id=, args=) 만 호출.
        self._web_search = web_search

    async def run_with_context(
        self, payload: WebSearchInput, *, context: ToolContext
    ) -> tuple[WebSearchOutput, ToolUsage]:
        result = await self._web_search.run(
            owner_id=context.owner_id, args=payload.model_dump(exclude_none=True)
        )
        raw = result.payload if isinstance(result.payload, dict) else {}
        results = raw.get("results", [])
        return WebSearchOutput(results=results, count=len(results)), ToolUsage()
