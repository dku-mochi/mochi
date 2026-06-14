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

import json
import re
import time
from typing import Any, Literal, NamedTuple, cast
from urllib.parse import quote, urlencode, urlparse

import httpx
from google.genai import types
from pydantic import BaseModel, Field

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage
from app.modules.agent.infrastructure.gemini_agent_client import _shared_client
from app.shared.llm_usage import extract_token_usage

log = get_logger("agent.tool.resource_finder")

_JUDGE_MODEL = "gemini-3.1-flash-lite"   # final judge — 관련성 게이트(비용 최우선, 메인과 동일 모델)
_NAVER_SEARCH_URL = "https://openapi.naver.com/v1/search/{category}.json"
_TAVILY_SEARCH_URL = "https://api.tavily.com/search"
_DISPLAY = 10
_SORT = "sim"
_MAX_QUERIES = 5      # 메인이 분해한 키워드 검색 상한 — 영상 추천 리스트 등 과다 분해 시 비용 bound
_MAX_QUERY_LEN = 100  # 검색어 1개 길이 상한 — 외부 API 전 bound (너드킹 셔츠 전체나열 같은 폭주 방지)
_MAX_VISIBLE_URLS = 5
_TAG_RE = re.compile(r"<[^>]+>")


# ── judge 프롬프트 (lab exp5~7 + per-URL 전환 2026-06-14) ──────────────────────
# picks 의 usefulness 는 "자료 품질"이 아니라 "캡처 대상 일치도"다(codex 토론). 5/4 만 받는다 —
# 빗나간 링크는 picks 에 넣지 않고(=대상 아님), reference 로 자연 강등시킨다. 5 만 iOS "딱 맞아요"
# 뱃지를 켜므로 4("같은 대상군이나 정확한 그것인지 확신 부족")는 액션은 주되 뱃지는 끈다.
_JUDGE_PROMPT = (
    "너는 최종 평가자이자 게이트다. 모찌(개인 기억 비서)가 사용자 기록을 보고 자료를 탐색한 뒤 모은 "
    "최종 결과(제목/링크/요약)를 보고, 이걸 사용자에게 '혹시 이거 찾으세요?' 라며 실제로 보여줄 "
    "가치가 있는지 판단하라.\n"
    "- useful: 이 결과 URL 들을 사용자에게 붙여주는 게 정말 도움이 되는가. 기록이 가리킨 대상과 "
    "동떨어지거나, 단서가 빈약해 추측성 결과만 모였다면 false. 무용한 결과를 내보내지 않는 게 "
    "이 게이트의 목적이다.\n"
    "- picks: useful=true 면, 기록이 가리킨 '바로 그 대상'인 링크만 최대 3개 골라라(도움되는 순). "
    "각 pick 에 usefulness 를 매긴다 — 이건 자료 품질이 아니라 '캡처 대상과 같은 것인가'다:\n"
    "    · 5 = 캡처 대상의 정확한 URL/SKU/장소라고 확신.\n"
    "    · 4 = 같은 대상군이라 액션은 유용하나 정확한 URL/SKU/지점까지는 확신 부족.\n"
    "  관련은 있으나 빗나간(다른 브랜드·다른 상품·다른 지점·무관한 가게) 링크는 picks 에 넣지 마라 "
    "— 그런 건 대상이 아니다(자동으로 참고 자료로 내려간다). 단 사용자가 찾는 것이 본품이 아닌 "
    "부속품 자체(예: 그립톡·폰케이스·노트북 스킨)라면 그게 대상이므로 담아라.\n"
    "  **위 목록에 있는 link 문자열을 한 글자도 바꾸지 말고 그대로 복사하라**(슬래시·쿼리·m. 추가나 "
    "정규화 금지 — 변형하면 매칭이 깨진다). useful=false 면 반드시 빈 리스트 [] 로 둔다.\n"
    "- comment: 한 줄 근거(picks 가 비었으면 '딱 그건 못 찾았지만 참고자료는 있음'처럼 솔직히)."
)


class _Pick(BaseModel):
    # 대상 일치도. 5=확신(딱 맞아요 뱃지), 4=액션은 OK. 스키마는 1-5 로 관대하게 받고(structured
    # output 이 3 을 뱉어도 hard-fail 안 나게), 실제 4/5 게이트는 _exact_picks 가 코드로 건다.
    url: str
    usefulness: int = Field(ge=1, le=5)


class _FinalJudge(BaseModel):
    useful: bool
    picks: list[_Pick] = Field(default_factory=list)
    comment: str


def _exact_picks(picks: list[_Pick]) -> list[_Pick]:
    """대상 일치도 4/5 만 남긴다 — judge 가 빗나간 링크(3 이하)를 picks 에 넣어도(대상이 아님)
    구조검증 hard-fail 없이 걸러내, 그 URL 은 reference 로 자연 강등시킨다(codex 리뷰 내성)."""
    return [p for p in picks if p.usefulness >= 4]


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
_OFFICIAL_HOST_PATTERNS: tuple[str, ...] = (
    "abib.com", "apple.com", "baskinrobbins.co.kr", "coor.kr", "dasique.com",
    "depound.com", "emis.kr", "logitech.com", "locknlock.com", "matinkim.com",
    "react.dev", "romand.co.kr", "roundlab.co.kr", "samsung.com", "sie-official.kr",
    "torriden.com", "uniqlo.com",
)

RankProfile = Literal[
    "auto", "general", "cosmetics", "fashion", "electronics", "local",
    "event_booking", "coupang", "web",
]
SourceApp = Literal[
    "unknown", "coupang", "naver_map", "naver_shopping", "oliveyoung", "musinsa",
    "instagram", "youtube", "safari", "browser",
]


class ResourceFinderInput(BaseModel):
    # 메인이 결정한 검색어(분해 포함). 상한은 tool 내부에서 슬라이스로 적용한다 — pydantic
    # max_length 로 막으면 메인이 많이 분해한 turn 이 ValidationError 로 run 전체를 죽인다.
    queries: list[str] = Field(min_length=1)
    category: Literal["shop", "local", "blog", "news", "web"]
    original_url: str | None = None  # 캡처 원본 URL(있으면 tier0 원본일치 신호)
    visible_urls: list[str] = Field(default_factory=list)
    rank_profile: RankProfile = "auto"
    source_app: SourceApp = "unknown"


class RankedUrl(BaseModel):
    url: str
    title: str
    tier_num: float
    tier_label: str
    label: str
    provider: str
    role: str
    source: str
    rank_profile: str
    # 누르기 전 "어디서/얼마/무슨 글인지" 식별 단서 — 검색 시점에 이미 받은 메타를 흘린다(추가 fetch 0).
    subtitle: str = ""    # 카테고리별 부제: local="업종 · 지역" / blog·web=요약문 / shop=브랜드.
    price_text: str = ""  # shop lprice 가 있을 때만 "18,900원". provider 브랜드와 겹치는 몰名은 안 쓴다.


class ResourceFinderOutput(BaseModel):
    useful: bool
    usefulness: int
    ranked_urls: list[RankedUrl] = Field(default_factory=list)
    reference_entities: list[str] = Field(default_factory=list)
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
        if _needs_naver(payload) and not settings.naver_client_id:
            raise ToolExecutionError(self.name, "Naver search API key not configured")
        tin_total = tout_total = 0
        started = time.perf_counter()

        naver_headers = {
            "X-Naver-Client-Id": settings.naver_client_id or "",
            "X-Naver-Client-Secret": settings.naver_client_secret or "",
        }
        async with httpx.AsyncClient(headers=naver_headers, timeout=20) as http:
            searches = await self._run_search_plan(http, payload, settings.tavily_api_key)
            collected = _collect_items(searches)
            judge, tin, tout = await self._judge(payload, collected)
            tin_total += tin
            tout_total += tout

        ranked = _rank_results(judge, collected, payload)
        # usefulness 는 URL 별 신뢰 신호다 — judge 가 pick 한 링크에만 그 pick 의 값(4/5)을 싣고,
        # pick 밖(강등됐거나 참고)은 None 으로 둔다(iOS isExactMatch 가 다중 점등하던 버그 해소).
        picks_map = {_dedupe_key(p.url): p.usefulness for p in judge.picks if p.url}
        reference_entities = [
            _reference_entity_value(row, picks_map.get(_dedupe_key(row.url)))
            for row in ranked
        ]
        # top-level 단일값은 로그/구버전 호환용만 — 신뢰 UI 는 entity 별 usefulness 를 본다.
        output_usefulness = max(
            (p.usefulness for p in judge.picks), default=3 if judge.useful else 1
        )
        usage = ToolUsage(
            tokens_in=tin_total,
            tokens_out=tout_total,
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
        return (
            ResourceFinderOutput(
                useful=judge.useful,
                usefulness=output_usefulness,
                ranked_urls=ranked,
                reference_entities=reference_entities,
                comment=judge.comment,
            ),
            usage,
        )

    async def _run_search_plan(
        self, http: httpx.AsyncClient, payload: ResourceFinderInput, tavily_key: str | None
    ) -> list[dict[str, Any]]:
        searches: list[dict[str, Any]] = []
        observed = _observed_items(payload)
        if observed:
            searches.append({"query": "(observed)", "items": observed})
        place_confirmed = False
        for query in _prepared_queries(payload):
            for backend, category, effective in _search_plan(payload, query):
                if backend == "tavily":
                    if not tavily_key:
                        continue
                    res = await _search_tavily(http, tavily_key, effective)
                else:
                    res = await _search_naver(http, category, effective)
                    if category == "local" and res.get("items"):
                        place_confirmed = True
                searches.append({"query": effective, **res})
        # 캐치테이블 가게 직링크(ct/shop)가 잡혔으면 그 장소는 실존 → 지도 검색 링크도 유효.
        # 상호 띄어쓰기로 naver local 이 0건이어도 실존 신호를 놓치지 않는다.
        if not place_confirmed:
            place_confirmed = any(
                "catchtable.co.kr/ct/shop" in it.get("link", "")
                for s in searches for it in s.get("items", [])
            )
        # 장소 실존이 확인됐을 때만 지도/쿠팡 검색 fallback 합성(0건 깨진 링크 차단).
        fallback = _fallback_search_items(payload, place_confirmed)
        if fallback:
            searches.append({"query": "(fallback)", "items": fallback})
        return searches

    async def _judge(
        self, payload: ResourceFinderInput, collected: list[dict[str, Any]]
    ) -> tuple[_FinalJudge, int, int]:
        resp = await _generate(_JUDGE_MODEL, _JUDGE_PROMPT, _render(payload, collected), _FinalJudge)
        tin, tout = extract_token_usage(resp)
        out = _FinalJudge.model_validate_json(resp.text)
        if not out.useful:
            out.picks = []
        out.picks = _exact_picks(out.picks)[:3]
        return out, tin, tout


# ── 검색·정제·랭킹 헬퍼 (lab exp5~7 정본) ─────────────────────────────────────
def _strip_tags(text: str) -> str:
    return _TAG_RE.sub("", text).strip()


def _normalize_item(category: str, it: dict[str, Any]) -> dict[str, Any]:
    link = it.get("link") or it.get("originallink") or ""
    base = {
        "title": _strip_tags(it.get("title", "")),
        "link": link,
        "source": f"naver:{category}",
    }
    if category == "shop":
        base.update({"lprice": it.get("lprice", ""), "mallName": it.get("mallName", ""),
                     "brand": it.get("brand", "")})
    elif category == "local":
        base.update({
            "category": it.get("category", ""),
            "address": it.get("address", ""),
            "roadAddress": it.get("roadAddress", ""),
        })
    elif category in ("blog", "news", "webkr"):
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
                       "source": "tavily",
                       "description": (r.get("content", "") or "")[:200]}
                      for r in data.get("results", [])[:_DISPLAY]]}


def _collect_items(searches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for s in searches:
        for item in s.get("items", []):
            link = item.get("link", "")
            key = _dedupe_key(link)
            if not key or key in seen:
                continue
            seen.add(key)
            items.append(item)
    return items


def _needs_naver(payload: ResourceFinderInput) -> bool:
    profile = _rank_profile(payload)
    return payload.category != "web" or profile in {
        "cosmetics", "local", "event_booking", "coupang", "fashion"
    }


def _rank_profile(payload: ResourceFinderInput) -> str:
    if payload.rank_profile != "auto":
        return payload.rank_profile
    if payload.source_app == "coupang":
        return "coupang"
    if payload.source_app == "naver_map" or payload.category == "local":
        return "local"
    if payload.category == "web":
        return "web"
    return "general"


def _prepared_queries(payload: ResourceFinderInput) -> list[str]:
    profile = _rank_profile(payload)
    out: list[str] = []
    for raw in payload.queries[:_MAX_QUERIES]:
        q = " ".join(raw.split())[:_MAX_QUERY_LEN]
        if not q:
            continue
        variants = [q]
        if profile == "coupang" and "쿠팡" not in q:
            variants.insert(0, f"{q} 쿠팡")
        for variant in variants:
            if variant not in out:
                out.append(variant[:_MAX_QUERY_LEN])
    return out


def _search_backends(payload: ResourceFinderInput) -> list[tuple[str, str]]:
    profile = _rank_profile(payload)
    if profile == "fashion":
        return [("tavily", "web"), ("naver", "shop"), ("naver", "webkr")]
    if profile == "cosmetics":
        return [("naver", "shop"), ("tavily", "web"), ("naver", "webkr")]
    if profile == "local":
        return [("naver", "local"), ("tavily", "web"), ("naver", "webkr")]
    if profile == "event_booking":
        return [("naver", "webkr"), ("naver", "news"), ("tavily", "web"), ("naver", "blog")]
    if profile == "coupang":
        return [("tavily", "web"), ("naver", "shop"), ("naver", "webkr")]
    if payload.category == "web":
        return [("tavily", "web"), ("naver", "webkr")]
    if payload.category == "shop":
        return [("naver", "shop"), ("tavily", "web")]
    return [("naver", payload.category), ("tavily", "web")]


def _search_plan(
    payload: ResourceFinderInput, query: str
) -> list[tuple[str, str, str]]:
    """(backend, category, effective_query) 목록. 백본별로 검색어를 다르게 쓸 수 있다.

    장소·예약 회수(local/event_booking)는 webkr 백본에 "{query} 캐치테이블 예약" 변형을
    하나 더 던진다 — 캐치테이블 입점 가게는 ct/shop 직링크가 잡히고, 미입점이면 블로그만
    나와 랭킹에서 자연 탈락한다(코드 호텔/병원에 캐치테이블을 강제로 섞지 않는 안전한 확장).
    """
    plan = [(backend, category, query) for backend, category in _search_backends(payload)]
    if _rank_profile(payload) in {"local", "event_booking"}:
        plan.append(("naver", "webkr", f"{query} 캐치테이블 예약"))
    return plan


def _observed_items(payload: ResourceFinderInput) -> list[dict[str, Any]]:
    """화면에서 실제로 관측된 링크(visible/original) — 검색과 무관하게 늘 후보.

    OCR·공유 메타로 확인된 실재 URL 이라 합성 검색 링크와 달리 신뢰가 보장된다.
    """
    items: list[dict[str, Any]] = []
    for url in payload.visible_urls[:_MAX_VISIBLE_URLS]:
        if _is_http_url(url):
            items.append({
                "title": "화면 속 링크",
                "link": url,
                "source": "visible_url",
                "synthetic": True,
            })
    original_url = payload.original_url
    if original_url and _is_http_url(original_url):
        items.append({
            "title": "원본 링크",
            "link": original_url,
            "source": "original_url",
            "synthetic": True,
        })
    return items


def _fallback_search_items(
    payload: ResourceFinderInput, place_confirmed: bool
) -> list[dict[str, Any]]:
    """검색 재개용 합성 링크(네이버지도·쿠팡 검색 URL).

    이건 실제 place/PDP URL 이 아니라 "그 쿼리로 다시 검색하는" URL 이다. 그래서 지도
    링크는 그 장소의 실존이 검색으로 **확인됐을 때만**(place_confirmed) 만든다 — 0건이면
    빈손 검색 페이지로 보내는 깨진 링크가 되기 때문(해외 호텔이 1위로 오던 회귀의 근본원인).
    합성 링크는 _profile_score 에서 같은 provider 의 실재 결과보다 뒤로 강등된다.
    """
    items: list[dict[str, Any]] = []
    profile = _rank_profile(payload)
    queries = _prepared_queries(payload)
    first_query = queries[0] if queries else ""
    if not first_query:
        return items
    if profile == "local" and place_confirmed:
        items.append({
            "title": f"{first_query} - 네이버 지도 검색",
            "link": _naver_map_search_url(first_query),
            "source": "synthetic:naver_map",
            "synthetic": True,
        })
    if profile == "coupang":
        query = first_query.replace(" 쿠팡", "")
        items.append({
            "title": f"{query} - 쿠팡 검색",
            "link": _coupang_search_url(query),
            "source": "synthetic:coupang_search",
            "synthetic": True,
        })
    return items


def _naver_map_search_url(query: str) -> str:
    return "https://map.naver.com/p/search/" + quote(query)


def _coupang_search_url(query: str) -> str:
    return "https://www.coupang.com/np/search?" + urlencode({"q": query})


def _is_http_url(url: str) -> bool:
    try:
        parsed = urlparse(url)
    except ValueError:
        return False
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def _render(payload: ResourceFinderInput, collected: list[dict[str, Any]]) -> str:
    lines = [(
        "사용자 기록: "
        f"category={payload.category}, rank_profile={_rank_profile(payload)}, "
        f"source_app={payload.source_app}, queries={payload.queries}"
    ),
             "지금까지 모은 결과:"]
    if collected:
        for i, it in enumerate(collected):
            extra = it.get("description", "")
            # 같은 SKU·다른 지점 판단을 judge 에 위임했으니, 제목·링크 외에 _normalize_item 이 모은
            # 구조 필드(쇼핑몰/가격/브랜드/주소)도 보여줘야 judge 가 동일성을 가릴 근거가 생긴다.
            meta = " ".join(
                f"[{k}={it[k]}]"
                for k in ("mallName", "lprice", "brand", "category", "roadAddress", "address")
                if it.get(k)
            )
            line = f"  {i + 1}. {it.get('title', '')} | {it.get('link', '')}"
            if extra:
                line += f" — {extra[:80]}"
            if meta:
                line += f" {meta}"
            lines.append(line)
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


def _dedupe_key(url: str) -> str:
    host = _host(url)
    if not host:
        return ""
    if host.startswith("m."):
        host = host[2:]
    key = host.rstrip("/")
    # 쿼리로 식별되는 페이지(youtube ?v=, goods_view.php?goodsNo=, 검색 ?q= 등)가 host+path
    # 만으로 충돌하면 한 pick 이 다른 URL 에 usefulness 를 잘못 전염시킨다(codex P1). judge 는 후보
    # link 를 그대로 복사하므로(프롬프트) 원본 쿼리 보존 비교로 충분. 쿼리 값은 대소문자를 구분
    # (youtube ?v=AbC ≠ ?v=abc, 토큰/ID) 하므로 host·path 와 달리 소문자화하지 않는다(codex P1).
    try:
        query = urlparse(url).query
    except ValueError:
        query = ""
    return f"{key}?{query}" if query else key


def _contains_any(text: str, needles: tuple[str, ...]) -> bool:
    lowered = text.lower()
    return any(n.lower() in lowered for n in needles)


def _provider(item: dict[str, Any]) -> str:
    link = item.get("link", "") or ""
    host = _host(link)
    mall = item.get("mallName", "") or ""
    source = item.get("source", "") or ""
    if source == "visible_url":
        return "visible_url"
    if source == "original_url":
        return "original_url"
    if "map.naver.com" in host or "place.naver.com" in host or source == "synthetic:naver_map":
        return "naver_map"
    if "catchtable" in host:
        return "catchtable"
    if "oliveyoung" in host or "올리브영" in mall:
        return "oliveyoung"
    if "musinsa" in host or "무신사" in mall:
        return "musinsa"
    if "29cm" in host or "29cm" in mall:
        return "29cm"
    if "wconcept" in host or "더블유컨셉" in mall:
        return "wconcept"
    if "zigzag" in host or "지그재그" in mall:
        return "zigzag"
    if "coupang" in host or "쿠팡" in mall or source == "synthetic:coupang_search":
        return "coupang"
    if "smartstore.naver.com" in host or "스마트스토어" in mall:
        return "smartstore"
    if "search.shopping.naver.com" in host or mall == "네이버":
        return "naver_shopping"
    if _contains_any(host, ("danawa", "11st", "gmarket", "auction", "ssg.com", "shoppinghow")):
        return "openmarket"
    if _contains_any(host, ("blog.naver.com", "tistory.com", "brunch.co.kr", "medium.com", "velog.io")):
        return "info"
    if _contains_any(host, ("instagram.com", "facebook.com", "threads.com")):
        return "social"
    if _contains_any(host, _OFFICIAL_HOST_PATTERNS):
        return "official"
    if _contains_any(host, (".go.kr", "go.kr", "seoul.go.kr", "youth.seoul.go.kr")):
        return "official"
    if host:
        return "site"
    return "unknown"


def _label(provider: str, role: str) -> str:
    labels = {
        "visible_url": "화면 속 링크 열기",
        "original_url": "원본에서 보기",
        "naver_map": "네이버 지도에서 보기",
        "catchtable": "캐치테이블에서 예약",
        "oliveyoung": "올리브영에서 보기",
        "musinsa": "무신사에서 보기",
        "29cm": "29CM에서 보기",
        "wconcept": "W컨셉에서 보기",
        "zigzag": "지그재그에서 보기",
        "coupang": "쿠팡에서 보기",
        "smartstore": "네이버 스마트스토어에서 보기",
        "naver_shopping": "네이버쇼핑에서 보기",
        "official": "공식 사이트에서 보기",
        "site": "관련 사이트 보기",
        "info": "관련 글 보기",
        "social": "SNS에서 보기",
    }
    if provider == "unknown":
        return "예약 링크 열기" if role == "reserve" else "관련 링크 열기"
    return labels.get(provider, "관련 링크 열기")


# role 은 provider 가 가리키는 행동 종류(iOS roleIcon·CTA 동사). payload 단위 하나가 아니라
# URL 단위로 정해야 한다 — local 이라고 블로그 후기까지 "예약"이 되면 안 된다(codex 리뷰).
_PROVIDER_ROLE: dict[str, str] = {
    "naver_map": "reserve", "catchtable": "reserve",
    "coupang": "buy", "smartstore": "buy", "oliveyoung": "buy", "musinsa": "buy",
    "29cm": "buy", "wconcept": "buy", "zigzag": "buy", "naver_shopping": "buy",
    "openmarket": "buy",
    "info": "read", "social": "read",
    "official": "reference", "site": "reference",
    "visible_url": "reference", "original_url": "reference",
}


def _role(provider: str, payload: ResourceFinderInput) -> str:
    role = _PROVIDER_ROLE.get(provider)
    if role:
        return role
    if _rank_profile(payload) == "event_booking":
        return "book"
    if payload.category == "shop":
        return "buy"
    if payload.category in {"blog", "news", "web"}:
        return "read"
    return "reference"


# intent bucket — URL 이 "어떤 다음 행동"인지. top3 다양성 quota 의 단위.
#   observed       관측된 실제 링크(visible/original)
#   primary_action 바로 액션(지도/예약/구매)
#   official       공식 사이트
#   reference      참고 자료(블로그/SNS/일반 사이트)
# 합성 검색 링크(synthetic:naver_map 등)는 provider 가 naver_map/coupang 이라 primary_action
# 에 들되, returned>0 게이트로 신뢰가 보장되고 _synthetic_penalty 로 실재 결과보다 뒤로 간다.
_PRIMARY_ACTION_PROVIDERS: frozenset[str] = frozenset({
    "naver_map", "catchtable", "coupang", "smartstore", "oliveyoung",
    "musinsa", "29cm", "wconcept", "zigzag", "naver_shopping", "openmarket",
})


def _bucket(provider: str) -> str:
    if provider in {"visible_url", "original_url"}:
        return "observed"
    if provider == "official":
        return "official"
    if provider in _PRIMARY_ACTION_PROVIDERS:
        return "primary_action"
    return "reference"


# 반복적으로 끼던 저품질 도메인 — 대상과 무관한 무드보드/기계번역 미러(LLM-judge 20건).
# 의미 없는 좁은 도메인 집합만 — "어떤 상품이 액세서리냐" 같은 의미 판단은 룰이 아니라
# judge 에게 맡긴다(룰로 박으면 진짜 그 액세서리를 찾는 사용자를 죽인다).
_NOISE_HOST_PATTERNS: tuple[str, ...] = ("pinterest.", "site-translation.com")


def _is_noise(item: dict[str, Any]) -> bool:
    return _contains_any(_host(item.get("link", "") or ""), _NOISE_HOST_PATTERNS)


def _filtered_candidates(
    collected: list[dict[str, Any]], payload: ResourceFinderInput
) -> list[dict[str, Any]]:
    """noise 도메인만 제거. 대상 일치(엉뚱한 가게/부속품) 판단은 judge.picked_urls 가 한다."""
    return [it for it in collected if not _is_noise(it)]


# 각 profile 이 top3 에 담고 싶은 bucket 선호 순서. 서로 다른 bucket 을 한 칸씩 먼저 채워
# "액션 + 참고" 믹스를 만든다 — 지도/예약만 3칸을 점령하던 overfit 을 푼다. 남는 칸은
# score 순 best-remaining 으로 메우므로, 액션이 둘이면 자연히 둘째 액션도 들어온다.
_QUOTA_ORDER: dict[str, list[str]] = {
    "local": ["primary_action", "reference", "official"],
    "event_booking": ["official", "primary_action", "reference"],
    "cosmetics": ["primary_action", "official", "reference"],
    "fashion": ["primary_action", "official", "reference"],
    "coupang": ["primary_action", "official", "reference"],
    "electronics": ["primary_action", "official", "reference"],
    "web": ["primary_action", "reference", "official"],
    "general": ["primary_action", "reference", "official"],
}


class _Cand(NamedTuple):
    score: float
    order: int
    item: dict[str, Any]
    provider: str
    bucket: str
    tier_num: float
    tier_label: str
    demoted: bool = False


def _select_diverse(rows: list[_Cand], profile: str, limit: int = 3) -> list[_Cand]:
    """score 정렬 후 bucket quota 로 채운다 — 단순 top-N sort 가 아니라 다양성 우선."""
    rows_sorted = sorted(rows, key=lambda c: (c.score, c.order))
    by_bucket: dict[str, list[_Cand]] = {}
    for c in rows_sorted:
        by_bucket.setdefault(c.bucket, []).append(c)
    chosen: list[_Cand] = []
    used: set[int] = set()

    def take(c: _Cand) -> None:
        chosen.append(c)
        used.add(c.order)

    for c in by_bucket.get("observed", []):       # 관측 링크는 무조건 우선
        if len(chosen) < limit and c.order not in used:
            take(c)
    for bucket in _QUOTA_ORDER.get(profile, _QUOTA_ORDER["general"]):
        if len(chosen) >= limit:
            break
        for c in by_bucket.get(bucket, []):       # 선호 bucket 에서 한 칸씩
            if c.order not in used:
                take(c)
                break
    seen_providers = {c.provider for c in chosen}
    for c in rows_sorted:                         # 남는 칸: 우선 새 provider
        if len(chosen) >= limit:
            break
        if c.order not in used and c.provider not in seen_providers:
            take(c)
            seen_providers.add(c.provider)
    for c in rows_sorted:                         # 그래도 남으면 score 순(중복 허용)
        if len(chosen) >= limit:
            break
        if c.order not in used:
            take(c)
    chosen.sort(key=lambda c: (c.score, c.order))
    return chosen[:limit]


def _profile_score(provider: str, profile: str, item: dict[str, Any]) -> float:
    if provider in {"visible_url", "original_url"}:
        return 0.0
    return _base_profile_score(provider, profile, item) + _synthetic_penalty(item)


def _synthetic_penalty(item: dict[str, Any]) -> float:
    """합성 검색 URL(네이버지도·쿠팡 검색)을 같은 provider 의 실재 결과보다 뒤로.

    검색 매칭됐을 때만 생성되므로 깨진 링크는 아니지만, 실제 place/PDP 가 있으면 그게
    먼저 보여야 한다. 0.3 은 티어 간격(보통 1.0)보다 작아 같은 provider 안에서만 밀린다.
    """
    return 0.3 if str(item.get("source", "")).startswith("synthetic:") else 0.0


def _base_profile_score(provider: str, profile: str, item: dict[str, Any]) -> float:
    if profile == "local":
        order = {
            "naver_map": 1.0,
            "catchtable": 2.0,
            "official": 3.0,
            "social": 4.0,
            "site": 4.5,
            "info": 5.0,
        }
        return order.get(provider, 6.0)
    if profile == "cosmetics":
        order = {
            "oliveyoung": 1.0,
            "official": 2.0,
            "smartstore": 3.0,
            "coupang": 4.0,
            "naver_shopping": 5.0,
            "openmarket": 6.0,
            "site": 6.5,
            "info": 7.0,
        }
        return order.get(provider, 7.5)
    if profile == "fashion":
        order = {
            "official": 1.0,
            "musinsa": 1.1,
            "29cm": 1.2,
            "wconcept": 1.3,
            "zigzag": 1.4,
            "smartstore": 3.0,
            "coupang": 4.0,
            "naver_shopping": 4.2,
            "openmarket": 5.0,
            "site": 5.5,
            "info": 6.0,
        }
        return order.get(provider, 6.5)
    if profile == "coupang":
        order = {
            "coupang": 1.0,
            "official": 2.0,
            "smartstore": 3.0,
            "naver_shopping": 4.0,
            "openmarket": 5.0,
            "site": 5.5,
            "info": 6.0,
        }
        return order.get(provider, 6.5)
    if profile == "event_booking":
        order = {
            "official": 1.0,
            "naver_map": 2.0,
            "catchtable": 2.5,
            "social": 3.5,
            "site": 3.8,
            "info": 4.0,
        }
        return order.get(provider, 4.5)
    if profile == "electronics":
        order = {
            "official": 1.0,
            "smartstore": 2.0,
            "coupang": 3.0,
            "naver_shopping": 4.0,
            "openmarket": 4.5,
            "site": 4.8,
            "info": 5.0,
        }
        return order.get(provider, 5.5)
    return _legacy_score(item)


def _legacy_score(item: dict[str, Any]) -> float:
    provider = _provider(item)
    order = {
        "naver_map": 1.0,
        "catchtable": 1.5,
        "official": 2.0,
        "oliveyoung": 2.0,
        "musinsa": 2.0,
        "29cm": 2.0,
        "wconcept": 2.0,
        "smartstore": 3.0,
        "coupang": 3.2,
        "naver_shopping": 3.5,
        "openmarket": 3.8,
        "site": 3.9,
        "info": 4.0,
        "social": 4.5,
    }
    return order.get(provider, 4.8)


def _classify_tier(item: dict[str, Any], payload: ResourceFinderInput) -> tuple[float, str]:
    link = item.get("link", "") or ""
    host = _host(link)
    if payload.original_url:
        case_netloc = _host(payload.original_url).split("/")[0]
        link_netloc = host.split("/")[0]
        if case_netloc and link_netloc and case_netloc == link_netloc:
            return 0.0, _TIER_LABEL[0.0]
    score = _profile_score(_provider(item), _rank_profile(payload), item)
    if score <= 0:
        return 0.0, _TIER_LABEL[0.0]
    if score <= 1.5:
        return 1.0, _TIER_LABEL[1.0]
    if score <= 2.5:
        return 2.0, _TIER_LABEL[2.0]
    if score <= 3.5:
        return 3.0, _TIER_LABEL[3.0]
    if score <= 4.5:
        return 3.6, _TIER_LABEL[3.6]
    return 4.0, _TIER_LABEL[4.0]


def _rank_results(
    judge: _FinalJudge, collected: list[dict[str, Any]], payload: ResourceFinderInput
) -> list[RankedUrl]:
    if not judge.useful:
        return []
    # picked 가 랭킹의 핵심 신호이므로 raw string 이 아니라 _dedupe_key 로 정규화 비교한다 —
    # judge 가 trailing slash·m.·쿼리만 손대도 매칭이 깨지지 않게(codex 리뷰).
    picked = {_dedupe_key(p.url) for p in judge.picks if p.url}
    profile = _rank_profile(payload)
    rows: list[_Cand] = []
    for order, it in enumerate(_filtered_candidates(collected, payload)):
        provider = _provider(it)
        link = it.get("link", "")
        is_synthetic = str(it.get("source", "")).startswith("synthetic:")
        is_picked = _dedupe_key(link) in picked
        bucket = _bucket(provider)
        # judge 가 고른 링크는 동점 정렬에서 살짝 끌어올린다(useful 게이트만으로 안 끝나게).
        picked_bonus = -0.15 if (is_picked and not is_synthetic) else 0.0
        score = _profile_score(provider, profile, it) + picked_bonus
        # 예약/구매 액션 링크는 judge 가 "정말 그 대상"이라 인정(picked)한 것만 상위 액션 슬롯에.
        # judge 가 안 고른 액션(엉뚱한 가게·다른 SKU·본품 아닌 부속품)은 참고로 강등하고 뒤로 민다.
        # 의미 판단을 룰이 아니라 judge 에 맡겨, 진짜 그 부속품을 찾는 캡처는 그대로 액션으로 산다.
        # 경계는 "synthetic 여부"가 아니라 "링크 종류"다(codex 토론): real PDP/place URL 은
        # "이게 그 대상"이라는 주장이라 picked 가 없으면(judge 확신 0) 강등하지만, synthetic 검색
        # 상태 링크는 "이 검색에서 이어서 확인"하는 핸드오프라 picks=[] 여도 fallback 액션으로 남는다.
        demoted = bucket == "primary_action" and not is_picked and not is_synthetic
        if demoted:
            bucket = "reference"
            score += 1.0
        tier_num, tier_label = _classify_tier(it, payload)
        rows.append(_Cand(score, order, it, provider, bucket, tier_num, tier_label, demoted))
    results: list[RankedUrl] = []
    for c in _select_diverse(rows, profile):
        # 강등된 액션은 출력의 CTA·role·tier 까지 참고로 낮춘다 — bucket 만 바꾸면 화면엔
        # 여전히 "쿠팡에서 보기" 액션 버튼으로 나가던 버그(codex 리뷰).
        role = "reference" if c.demoted else _role(c.provider, payload)
        label = "관련 링크 보기" if c.demoted else _label(c.provider, role)
        tier_num = 4.0 if c.demoted else c.tier_num
        tier_label = _TIER_LABEL[4.0] if c.demoted else c.tier_label
        subtitle, price_text = _display_meta(c.item)
        results.append(RankedUrl(
            url=c.item.get("link", ""), title=c.item.get("title", ""),
            tier_num=tier_num, tier_label=tier_label, label=label,
            provider=c.provider, role=role,
            source=c.item.get("source", ""), rank_profile=profile,
            subtitle=subtitle, price_text=price_text,
        ))
    return results


def _short_region(addr: str) -> str:
    """도로명/지번 주소에서 시·구만 — 카드 한 줄에 들어갈 지역 식별자(앞 2토큰)."""
    parts = addr.split()
    return " ".join(parts[:2]) if parts else ""


def _display_meta(item: dict[str, Any]) -> tuple[str, str]:
    """검색 메타를 카드 표시용 (subtitle, price_text)로 환원한다 — 없으면 빈 문자열.

    카드는 이미 provider 로 브랜드 타일·이름을 그리므로 그와 겹치는 mallName 은 쓰지 않고,
    "무슨 글 / 어디 / 얼마"만 보탠다. subtitle 우선순위: local(업종·지역) > 요약문 > 브랜드.
    """
    price_text = ""
    lprice = str(item.get("lprice") or "").strip()
    if lprice.isdigit():
        price_text = f"{int(lprice):,}원"

    subtitle = ""
    category = str(item.get("category") or "").strip()
    region = _short_region(str(item.get("roadAddress") or item.get("address") or "").strip())
    if category or region:                                  # local: "양식점 · 서울 강남구"
        subtitle = " · ".join(p for p in (category, region) if p)
    elif (desc := str(item.get("description") or "").strip()):  # blog/news/web: 요약문
        subtitle = desc[:80]
    elif (brand := str(item.get("brand") or "").strip()):       # shop: 브랜드
        subtitle = brand
    return subtitle, price_text


def _reference_entity_value(row: RankedUrl, usefulness: int | None) -> str:
    payload: dict[str, Any] = {
        "url": row.url,
        "title": row.title,
        "label": row.label,
        "role": row.role,
        "provider": row.provider,
        "rankProfile": row.rank_profile,
        "source": row.source,
    }
    # subtitle·priceText·usefulness 는 값이 있을 때만 싣는다 — 빈 키를 빼서 iOS 가 None 으로 읽고
    # (부제·가격 pill 미표시, 뱃지 OFF), 메타 없는 링크(visible/original/synthetic)는 폴백한다.
    if row.subtitle:
        payload["subtitle"] = row.subtitle
    if row.price_text:
        payload["priceText"] = row.price_text
    if usefulness is not None:
        payload["usefulness"] = usefulness
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
