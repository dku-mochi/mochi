"""findReferenceUrls — 캡처에 붙일 "참고 가능한 실재 URL" 을 찾아오는 tool.

배경 (lab/active/shopping-product-link exp4~7, journal 2026-06-14):
  네이버 검색 API(shop/local/blog/news 단일 백본) + Tavily(해외/일반 web 폴백)로 캡처가
  가리킨 대상의 실재 URL 을 찾는다. 환각 0(전부 실재 검색). 무용한 결과는 final judge
  게이트가 빈손으로 막는다("혹시 이거?" 신뢰의 핵심).

exp 와의 차이 — 키워드 추출은 이 tool 이 아니라 **메인 에이전트(이미지를 봄)** 가 한다:
  exp6~7 의 generic 실패 근본원인이 "미니가 빈약한 summary 로 키워드 생성"이었다. 이미지를
  보는 메인이 queries+category 를 결정해 넘기면 그 원인이 제거된다(라이브 테스트 가설1).
  따라서 이 tool 은 route 단계 없이 search→judge 게이트→액션티어 랭킹만 수행한다.

  exp5~7 의 self-critique loop 는 제거했다 — baseline 에서 refine 기여가 낮았고(대부분 1-iter),
  무엇보다 loop 가 매 iter `collected` 를 덮어써 judge 가 마지막 검색만 보던 버그가 있었다
  (codex 리뷰 2026-06-14). 메인이 좋은 키워드를 주므로 검색 1회 + judge 게이트로 충분하다.

내부 LLM(judge=3.5-flash)은 ``_shared_client`` 를 재사용하고 토큰을 ``ToolUsage`` 로 반환해
orchestrator 가 비용에 집계한다. 외부 검색은 고정 호스트(openapi.naver.com / api.tavily.com)라
가변 URL SSRF 면이 아니다(web_search 선례와 동일).
"""

import re
import time
from typing import Any, Literal, cast
from urllib.parse import quote, urlparse

import httpx
from google.genai import types
from pydantic import BaseModel, Field

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage
from app.modules.agent.infrastructure.gemini_agent_client import _shared_client
from app.shared.llm_usage import extract_token_usage

log = get_logger("agent.tool.resource_finder")

_JUDGE_MODEL = "gemini-3.5-flash"   # final judge — 관련성 게이트(비용 지배분, 추후 flash-lite 검토)
_NAVER_SEARCH_URL = "https://openapi.naver.com/v1/search/{category}.json"
_TAVILY_SEARCH_URL = "https://api.tavily.com/search"
_DISPLAY = 3
_SORT = "sim"
_MAX_QUERIES = 5      # 메인이 분해한 키워드 검색 상한 — 영상 추천 리스트 등 과다 분해 시 비용 bound
_MAX_QUERY_LEN = 100  # 검색어 1개 길이 상한 — 외부 API 전 bound (너드킹 셔츠 전체나열 같은 폭주 방지)
_TAG_RE = re.compile(r"<[^>]+>")


# ── judge 프롬프트 (lab exp5~7 정본) ──────────────────────────────────────────
_JUDGE_PROMPT = (
    "너는 최종 평가자이자 게이트다. 모찌(개인 기억 비서)가 사용자 기록을 보고 자료를 탐색한 뒤 모은 "
    "최종 결과(제목/링크/요약)를 보고, 이걸 사용자에게 '혹시 이거 찾으세요?' 라며 실제로 보여줄 "
    "가치가 있는지 판단하라.\n"
    "- useful: 이 결과 URL 들을 사용자에게 붙여주는 게 정말 도움이 되는가. 기록이 가리킨 대상과 "
    "동떨어지거나, 단서가 빈약해 추측성 결과만 모였다면 false. 무용한 결과를 내보내지 않는 게 "
    "이 게이트의 목적이다.\n"
    "- usefulness (1-5): 5=기록이 가리킨 바로 그 자료/상품/장소가 상위에 있음, 3=관련은 있으나 "
    "빗나감, 1=전혀 무관.\n"
    "- picked_urls: useful=true 면, 사용자에게 보여줄 만한 링크를 최대 3개 골라 담아라. "
    "useful=false 면 반드시 빈 리스트 [] 로 둔다.\n"
    "- comment: 한 줄 근거."
)


class _FinalJudge(BaseModel):
    useful: bool
    usefulness: int = Field(ge=1, le=5)
    picked_urls: list[str] = Field(default_factory=list)
    comment: str


# ── 액션티어 랭킹 (결정적, LLM 아님 — lab exp7 정본) ───────────────────────────
# tier = "들어가서 바로 액션(예약/구매/시청)이 되는가 + 정확한가". 작을수록 우선.
#   0 원본일치 / 1 공식 / 2 편집샵 / 3 오픈마켓·직구·가격비교 / 4 정보.
_DOMAIN_TIER: dict[str, float] = {
    "netflix.com": 1.0, "youtube.com": 1.0, "youtu.be": 1.0,
    "map.naver.com": 1.0, "place.naver.com": 1.0,
    "lottecinema.com": 1.0, "cgv.co.kr": 1.0, "megabox.co.kr": 1.0,
    "myrealtrip.com": 1.0, "catchtable.co.kr": 1.0,
    "oliveyoung": 2.0, "musinsa": 2.0, "29cm": 2.0, "wconcept": 2.0,
    "zigzag": 2.0, "kream": 2.0, "ably": 2.0, "brandi": 2.0,
    "coupang": 3.0, "smartstore.naver.com": 3.0,
    "aliexpress": 3.3, "temu": 3.3,
    "11st": 3.6, "gmarket": 3.6, "auction": 3.6, "danawa": 3.6, "google": 3.6,
    "search.shopping.naver.com/catalog": 3.6,
    "blog.naver.com": 4.0, "tistory.com": 4.0, "brunch.co.kr": 4.0,
    "medium.com": 4.0, "velog.io": 4.0,
}
_MALL_TIER: dict[str, float] = {
    "올리브영": 2.0, "무신사": 2.0, "29cm": 2.0, "에이블리": 2.0, "브랜디": 2.0,
    "쿠팡": 3.0, "스마트스토어": 3.0, "알리": 3.3, "테무": 3.3,
    "11번가": 3.6, "지마켓": 3.6, "옥션": 3.6, "다나와": 3.6,
}
_TIER_LABEL = {
    0.0: "tier0_original", 1.0: "tier1_official", 2.0: "tier2_editorial",
    3.0: "tier3_openmarket", 3.3: "tier3_overseas", 3.6: "tier3_pricecompare",
    4.0: "tier4_info",
}


class ResourceFinderInput(BaseModel):
    # 메인이 결정한 검색어(분해 포함). 상한은 tool 내부에서 슬라이스로 적용한다 — pydantic
    # max_length 로 막으면 메인이 많이 분해한 turn 이 ValidationError 로 run 전체를 죽인다.
    queries: list[str] = Field(min_length=1)
    category: Literal["shop", "local", "blog", "news", "web"]
    original_url: str | None = None  # 캡처 원본 URL(있으면 tier0 원본일치 신호)


class RankedUrl(BaseModel):
    url: str
    title: str
    tier_num: float
    tier_label: str


class ResourceFinderOutput(BaseModel):
    useful: bool
    usefulness: int
    ranked_urls: list[RankedUrl] = Field(default_factory=list)
    comment: str


class ResourceFinderTool(Tool[ResourceFinderInput, ResourceFinderOutput]):
    """캡처에 붙일 참고 URL 을 찾는다(검색→critique→judge 게이트→액션티어 랭킹).

    키워드(queries)+category 는 이미지를 본 메인 에이전트가 넘긴다. useful=false 면
    ranked_urls=[] 로 빈손(무용 결과를 내보내지 않는 게이트).
    """

    name = ToolName.RESOURCE_FINDER
    input_model = ResourceFinderInput
    output_model = ResourceFinderOutput

    async def run(
        self, payload: ResourceFinderInput
    ) -> tuple[ResourceFinderOutput, ToolUsage]:
        settings = get_settings()
        if payload.category != "web" and not settings.naver_client_id:
            raise ToolExecutionError(self.name, "Naver search API key not configured")
        tin_total = tout_total = 0
        started = time.perf_counter()

        naver_headers = {
            "X-Naver-Client-Id": settings.naver_client_id or "",
            "X-Naver-Client-Secret": settings.naver_client_secret or "",
        }
        async with httpx.AsyncClient(headers=naver_headers, timeout=20) as http:
            queries = [q[:_MAX_QUERY_LEN] for q in payload.queries[:_MAX_QUERIES]]
            searches = [
                await self._run_query(http, payload.category, q, settings.tavily_api_key)
                for q in queries
            ]
            collected = _collect_items(searches)
            judge, tin, tout = await self._judge(payload, collected)
            tin_total += tin
            tout_total += tout

        ranked = _rank_results(judge, collected, payload.category, payload.original_url)
        usage = ToolUsage(
            tokens_in=tin_total,
            tokens_out=tout_total,
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
        return (
            ResourceFinderOutput(
                useful=judge.useful,
                usefulness=judge.usefulness,
                ranked_urls=ranked,
                comment=judge.comment,
            ),
            usage,
        )

    async def _run_query(
        self, http: httpx.AsyncClient, category: str, query: str, tavily_key: str | None
    ) -> dict[str, Any]:
        if category == "web":
            if not tavily_key:
                return {"query": query}
            res = await _search_tavily(http, tavily_key, query)
        else:
            res = await _search_naver(http, category, query)
        return {"query": query, **res}

    async def _judge(
        self, payload: ResourceFinderInput, collected: list[dict[str, Any]]
    ) -> tuple[_FinalJudge, int, int]:
        resp = await _generate(_JUDGE_MODEL, _JUDGE_PROMPT, _render(payload, collected), _FinalJudge)
        tin, tout = extract_token_usage(resp)
        out = _FinalJudge.model_validate_json(resp.text)
        if not out.useful:
            out.picked_urls = []
        out.picked_urls = out.picked_urls[:3]
        return out, tin, tout


# ── 검색·정제·랭킹 헬퍼 (lab exp5~7 정본) ─────────────────────────────────────
def _strip_tags(text: str) -> str:
    return _TAG_RE.sub("", text).strip()


def _normalize_item(category: str, it: dict[str, Any]) -> dict[str, Any]:
    base = {"title": _strip_tags(it.get("title", "")), "link": it.get("link", "")}
    if category == "shop":
        base.update({"lprice": it.get("lprice", ""), "mallName": it.get("mallName", ""),
                     "brand": it.get("brand", "")})
    elif category == "local":
        base.update({"address": it.get("address", ""), "roadAddress": it.get("roadAddress", "")})
    elif category in ("blog", "news"):
        base.update({"description": _strip_tags(it.get("description", ""))})
    return base


async def _search_naver(http: httpx.AsyncClient, category: str, query: str) -> dict[str, Any]:
    url = (_NAVER_SEARCH_URL.format(category=category)
           + f"?query={quote(query)}&display={_DISPLAY}&sort={_SORT}")
    try:
        resp = await http.get(url)
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("tool.resource_finder.naver_failed", category=category, error=str(exc))
        return {"items": []}
    return {"items": [_normalize_item(category, it) for it in data.get("items", [])[:_DISPLAY]]}


async def _search_tavily(http: httpx.AsyncClient, api_key: str, query: str) -> dict[str, Any]:
    try:
        resp = await http.post(
            _TAVILY_SEARCH_URL,
            json={"api_key": api_key, "query": query, "max_results": _DISPLAY,
                  "search_depth": "basic"},
        )
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("tool.resource_finder.tavily_failed", error=str(exc))
        return {"items": []}
    return {"items": [{"title": r.get("title", ""), "link": r.get("url", ""),
                       "description": (r.get("content", "") or "")[:200]}
                      for r in data.get("results", [])[:_DISPLAY]]}


def _collect_items(searches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for s in searches:
        items.extend(s.get("items", []))
    return items


def _render(payload: ResourceFinderInput, collected: list[dict[str, Any]]) -> str:
    lines = [f"사용자 기록: category={payload.category}, queries={payload.queries}",
             "지금까지 모은 결과:"]
    if collected:
        for i, it in enumerate(collected):
            extra = it.get("description", "")
            lines.append(f"  {i + 1}. {it.get('title', '')} | {it.get('link', '')}"
                         + (f" — {extra[:80]}" if extra else ""))
    else:
        lines.append("  (결과 없음)")
    return "\n".join(lines)


async def _generate(model: str, system: str, text: str, schema: type[BaseModel]) -> Any:
    contents = [types.Content(role="user", parts=[types.Part.from_text(text=text)])]
    return await _shared_client().aio.models.generate_content(
        model=model,
        contents=cast(types.ContentListUnion, contents),
        config=types.GenerateContentConfig(
            system_instruction=system,
            response_mime_type="application/json",
            response_schema=schema,
            temperature=0.0,
        ),
    )


def _host(url: str) -> str:
    try:
        p = urlparse(url)
    except ValueError:
        return ""
    host = (p.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host + (p.path or "").lower()


def _classify_tier(item: dict[str, Any], category: str, case_url: str | None) -> tuple[float, str]:
    link = item.get("link", "") or ""
    host = _host(link)
    if case_url:
        case_netloc = _host(case_url).split("/")[0]
        link_netloc = host.split("/")[0]
        if case_netloc and link_netloc and case_netloc == link_netloc:
            return 0.0, _TIER_LABEL[0.0]
    if category == "shop":
        mall = item.get("mallName", "") or ""
        for key, tier in _MALL_TIER.items():
            if key in mall:
                return tier, _TIER_LABEL[tier]
    for key, tier in _DOMAIN_TIER.items():
        if key in host:
            return tier, _TIER_LABEL[tier]
    if category == "shop":
        return 3.0, _TIER_LABEL[3.0]
    return 4.0, _TIER_LABEL[4.0]


def _rank_results(
    judge: _FinalJudge, collected: list[dict[str, Any]], category: str, case_url: str | None
) -> list[RankedUrl]:
    if not judge.useful:
        return []
    picked = set(judge.picked_urls)
    candidates = [it for it in collected if it.get("link", "") in picked] if picked else []
    if not candidates:
        candidates = list(collected)
    ranked = []
    for order, it in enumerate(candidates):
        tier_num, tier_label = _classify_tier(it, category, case_url)
        ranked.append((tier_num, order, it, tier_label))
    ranked.sort(key=lambda x: (x[0], x[1]))
    return [
        RankedUrl(url=it.get("link", ""), title=it.get("title", ""),
                  tier_num=tier_num, tier_label=tier_label)
        for tier_num, _order, it, tier_label in ranked[:3]
    ]
