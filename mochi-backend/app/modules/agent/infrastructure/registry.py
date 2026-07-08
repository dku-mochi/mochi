from collections.abc import Callable
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import get_settings
from app.modules.agent.domain.ports import ToolRegistry
from app.modules.agent.domain.tools import Tool, ToolName
from app.modules.agent.infrastructure.tools.place_geo import SearchPlaceGeoTool
from app.modules.agent.infrastructure.tools.platform_context import PlatformContextTool
from app.modules.agent.infrastructure.tools.resource_finder import ResourceFinderTool
from app.modules.agent.infrastructure.tools.web_fetch import WebFetchTool
from app.modules.agent.infrastructure.tools.youtube_recover import RecoverYoutubeUrlTool
from app.shared.voyage import VoyageClient


class StaticToolRegistry(ToolRegistry):
    """Agent loop 가 LLM 에 광고하는 호출 가능 도구.

    Arch2 — LLM 이 분석가다: 분류·요약·엔티티는 모델이 ``finalizeAnalysis`` 로 직접
    저술하므로 호출 도구로 둘 필요가 없고, embedding 은 결정적 후처리다 — orchestrator 가
    INDEXED 노드에서 ``DocumentEmbedder``(voyage)로 직접 색인하며 LLM 이 부르지 않는다.
    따라서 LLM 이 능동적으로 부를 도구는 URL 그라운딩용 ``platformContext``/``webFetch`` 뿐.
    (`MultimodalAnalyzeTool` 클래스는 스키마 재사용을 위해 보존.)
    """

    def __init__(
        self,
        *,
        session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession] | None = None,
        voyage: VoyageClient | None = None,
        tavily_api_key: str | None = None,
    ) -> None:
        self._tools: dict[ToolName, Tool[Any, Any]] = {
            ToolName.PLATFORM_CONTEXT: PlatformContextTool(),
            ToolName.WEB_FETCH: WebFetchTool(),
            # recoverYoutubeUrl 은 무키(공개 youtube 검색)라 항상 노출.
            ToolName.RECOVER_YOUTUBE_URL: RecoverYoutubeUrlTool(),
        }
        # findReferenceUrls/searchPlaceGeo 는 네이버 검색 키가 있을 때만 노출(키 발급이
        # 머지를 블록하지 않게 — web_search/Tavily 선례와 동일 패턴). secret 까지 확인 —
        # id 만 있으면 노출된 tool 이 전부 401 빈손으로 조용히 무력화된다(codex P3).
        settings = get_settings()
        if settings.naver_client_id and settings.naver_client_secret:
            self._tools[ToolName.RESOURCE_FINDER] = ResourceFinderTool()
            self._tools[ToolName.SEARCH_PLACE_GEO] = SearchPlaceGeoTool()
        # hybridSearch — 분석 중 과거 기록 능동 검색. session_factory 가 주입됐을 때만(테스트의
        # 무인자 StaticToolRegistry() 는 검색 없이 동작). conversations.application 경유로 모듈
        # 경계를 지킨다(여기서 conversations.infrastructure 를 직접 import 하지 않는다).
        if session_factory is not None:
            from app.modules.agent.infrastructure.tools.hybrid_search import HybridSearchTool
            from app.modules.conversations.application.tool_factories import make_search_items_tool

            self._tools[ToolName.HYBRID_SEARCH] = HybridSearchTool(
                make_search_items_tool(session_factory, voyage)
            )
        # webSearch — 외부 사실 그라운딩(KNOWLEDGE). Tavily 키가 있을 때만(키 발급이 머지를
        # 블록하지 않게 — findReferenceUrls/네이버 선례와 동일). 채팅 web_search 와 단일 구현 공유.
        if tavily_api_key:
            from app.modules.agent.infrastructure.tools.web_search import WebSearchAgentTool
            from app.modules.conversations.application.tool_factories import make_web_search_tool

            self._tools[ToolName.WEB_SEARCH] = WebSearchAgentTool(make_web_search_tool(tavily_api_key))

    def get(self, name: ToolName) -> Tool[Any, Any]:
        return self._tools[name]

    def all(self) -> list[Tool[Any, Any]]:
        return list(self._tools.values())
