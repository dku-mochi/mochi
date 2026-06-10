"""web_search — Tavily 웹 검색 채팅 툴 (read-only).

대표 시나리오 "오늘 데이트 어디서 할까?" 의 웹 추천 절반(journal 2026-06-10 설계 —
기록 회수는 search_items, 외부 정보는 여기). ``tavily_api_key`` 미설정 시 라우터가
레지스트리에서 제외하므로 이 클래스는 키 존재를 전제한다. 검색 엔드포인트는 고정
호스트(api.tavily.com)라 SSRF 가드 대상이 아니다 — 결과 URL 의 본문 페치는
web_fetch(가드 경유)가 담당. 기록 원문의 쿼리 반출 금지는 시스템 프롬프트
행동규칙이 가드한다 (PRIVACY 문서 §10).
"""

from typing import Any
from uuid import UUID

import httpx

from app.modules.conversations.domain.ports import ChatToolResult

_ENDPOINT = "https://api.tavily.com/search"
_TIMEOUT_SECONDS = 10.0
MAX_RESULTS = 5
CONTENT_CHARS = 400

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "query": {
            "type": "string",
            "description": (
                "Web search query. Never include the user's record contents or any "
                "personally identifying phrase — rephrase to a generic query."
            ),
        },
    },
    "required": ["query"],
}


class WebSearchTool:
    name = "web_search"
    label = "웹에서 찾아보고 있어요"
    description = (
        "Search the public web. Use for recommendations, places, current facts, or anything "
        "the user's saved records cannot contain. Snippets are short — follow up with "
        "web_fetch on a result url before relying on its details."
    )
    parameters = _PARAMETERS

    def __init__(self, api_key: str):
        self._api_key = api_key

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        query = str(args.get("query") or "").strip()
        if not query:
            return ChatToolResult(payload={"error": "query is required"}, summary="검색어가 비었어요")

        try:
            async with httpx.AsyncClient(timeout=_TIMEOUT_SECONDS) as client:
                response = await client.post(
                    _ENDPOINT,
                    json={"query": query, "max_results": MAX_RESULTS, "search_depth": "basic"},
                    headers={"Authorization": f"Bearer {self._api_key}"},
                )
        except httpx.HTTPError as exc:
            # 키·쿼리를 에러에 싣지 않는다 — 모델은 재시도/우회 판단만 하면 된다.
            return ChatToolResult(
                payload={"error": f"web search request failed: {type(exc).__name__}"},
                summary="웹 검색이 잠깐 막혔어요",
            )
        if response.status_code != 200:
            return ChatToolResult(
                payload={"error": f"web search failed: HTTP {response.status_code}"},
                summary="웹 검색이 잠깐 막혔어요",
            )

        raw_results = response.json().get("results") or []
        results = [
            {
                "title": str(item.get("title") or "")[:120],
                "url": str(item.get("url") or ""),
                "content": str(item.get("content") or "")[:CONTENT_CHARS],
            }
            for item in raw_results[:MAX_RESULTS]
            if isinstance(item, dict)
        ]
        return ChatToolResult(
            payload={"results": results, "count": len(results)},
            summary=f"웹에서 {len(results)}개를 찾았어요" if results else "웹에서 결과를 못 찾았어요",
            compact={"results": [{"title": r["title"], "url": r["url"]} for r in results[:3]]},
        )
