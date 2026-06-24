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
#: 한 호출 query 상한(search_items 와 동일) — 그 이상은 비용만.
_MAX_QUERIES = 4
#: 멀티쿼리 union 결과 상한 — 단일 query 면 MAX_RESULTS(5)로 자연 수렴.
_RESULTS_CAP = 10

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "One or more web search queries — issue several at once to cover different "
                "angles in a single call. Never include the user's record contents or any "
                "personally identifying phrase — rephrase each to a generic public query."
            ),
        },
    },
    "required": ["queries"],
}


def _parse_queries(args: dict[str, Any]) -> list[str]:
    """queries(list[str]) 우선, 단일 query(str) 하위호환. 빈 항목 제거 후 최대 _MAX_QUERIES."""
    raw = args.get("queries")
    if raw is None:
        single = args.get("query")
        raw = [single] if single else []
    elif isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    for item in raw:
        if isinstance(item, str):
            stripped = item.strip()
            if stripped and stripped not in out:  # 중복 query 제거 — 비용 4중 실행 방지
                out.append(stripped)
        if len(out) >= _MAX_QUERIES:
            break
    return out


class WebSearchTool:
    name = "web_search"
    label = "웹에서 찾아보고 있어요"
    description = (
        "Search the public web for what the user's saved records cannot contain: current "
        "facts, opening hours, reviews, news, general knowledge. For anything personal — "
        "tastes, places they marked, plans — their records come first (search_items); use "
        "this tool to enrich what you found there, or to fill what they never saved. Pass "
        "several queries at once to cover distinct angles in one call. Snippets are short — "
        "follow up with web_fetch on a result url before relying on its details."
    )
    parameters = _PARAMETERS

    def __init__(self, api_key: str):
        self._api_key = api_key

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        queries = _parse_queries(args)
        if not queries:
            return ChatToolResult(payload={"error": "queries is required"}, summary="검색어가 비었어요")

        collected: list[dict[str, str]] = []
        seen: set[str] = set()
        failed = 0
        async with httpx.AsyncClient(timeout=_TIMEOUT_SECONDS) as client:
            for query in queries:
                try:
                    response = await client.post(
                        _ENDPOINT,
                        json={"query": query, "max_results": MAX_RESULTS, "search_depth": "basic"},
                        headers={"Authorization": f"Bearer {self._api_key}"},
                    )
                    if response.status_code != 200:
                        failed += 1
                        continue
                    raw_results = response.json().get("results") or []
                except (httpx.HTTPError, ValueError):
                    # transport 실패·비정상 JSON(200+비JSON 의 ValueError 포함) 모두 그 query 만
                    # 건너뛰고 나머지 query 로 degrade. 여기서 안 잡으면 orchestrator `_run_tool`
                    # 의 except 가 ToolExecutionError/ValidationError 만 잡아 캡처 분석 run 전체가
                    # 죽고 outbox 재시도(Gemini 재분석 비용)로 이어진다. 키·쿼리는 안 싣는다.
                    failed += 1
                    continue
                for item in raw_results[:MAX_RESULTS]:
                    if not isinstance(item, dict):
                        continue
                    url = str(item.get("url") or "")
                    if not url or url in seen:  # URL 없는 결과 제외(web_fetch 후속 전제) + 중복 url 접기
                        continue
                    seen.add(url)
                    collected.append(
                        {
                            "title": str(item.get("title") or "")[:120],
                            "url": url,
                            "content": str(item.get("content") or "")[:CONTENT_CHARS],
                        }
                    )

        if not collected and failed:
            return ChatToolResult(
                payload={"error": "web search failed"},
                summary="웹 검색이 잠깐 막혔어요",
            )

        results = collected[:_RESULTS_CAP]
        return ChatToolResult(
            payload={"results": results, "count": len(results)},
            summary=f"웹에서 {len(results)}개를 찾았어요" if results else "웹에서 결과를 못 찾았어요",
            compact={"results": [{"title": r["title"], "url": r["url"]} for r in results[:3]]},
        )
