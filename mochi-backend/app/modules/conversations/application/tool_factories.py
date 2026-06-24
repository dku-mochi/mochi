"""채팅 검색 tool 의 cross-module 진입점 — agent 분석 에이전트가 hybridSearch 어댑터로 재사용한다.

모듈 경계(ARCHITECTURE §3.3): 다른 모듈은 conversations ``infrastructure/`` 를 직접 import 할 수
없다 — cross-module 진입은 ``application/`` 까지만. agent 가 ``SearchItemsTool`` 을 쓰려면 이
application 팩토리를 경유한다(agent 의 ``tool_factories.make_web_fetch_tool`` 과 대칭, 방향만 반대).
"""

from collections.abc import Callable

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.infrastructure.tools.search_items import SearchItemsTool
from app.modules.conversations.infrastructure.tools.web_search import WebSearchTool
from app.shared.voyage import VoyageClient


def make_search_items_tool(
    session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession],
    voyage: VoyageClient | None = None,
) -> SearchItemsTool:
    """owner 스코프 hybrid 검색 tool. 호출자(agent registry)가 자체 세션 팩토리·voyage 를 주입한다."""
    return SearchItemsTool(session_factory, voyage=voyage)


def make_web_search_tool(api_key: str) -> WebSearchTool:
    """Tavily 웹 검색 tool. tavily 키가 있을 때만 호출자가 만든다(키 없으면 registry 제외)."""
    return WebSearchTool(api_key)
