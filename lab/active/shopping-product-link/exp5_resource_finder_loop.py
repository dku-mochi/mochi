"""ResourceFinder loop-agent 실험 (exp5) — exp4 단발 파이프라인의 진화.

배경:
  exp4 는 route → search → judge 의 *단발* 파이프라인이었다(캡처 1개 → 라우팅 1회
  → 네이버 검색 1회 → judge 1회). exp5 는 ResourceFinder 를 자체 loop 를 도는
  mini-agent 로 만들어 세 가지를 추가 검증한다:

    1. 키워드 추출: 모호한 캡처("엄마 생신 선물")를 raw 검색하지 않고, 검색 가능한
       구체 키워드 여러 개로 분해해서 검색한다(예: ["여성 귀걸이 선물","여성 향수 추천"]).
    2. 웹검색 폴백: 네이버가 부적합한 주제(해외 제품·영어 주제·일반 웹)는 Tavily
       웹검색으로 폴백한다(category="web").
    3. self-critique loop + final judge: 수집 결과가 부족하면 critique 가 더 나은
       검색어를 1개 내고 재검색(최대 2 iter), 마지막에 final judge 가 "진짜 유용한가"
       를 판단해 무용하면 빈손(useful=false, picked_urls=[])으로 게이트한다.

파이프라인 (per case):
  1. route (ROUTER_MODEL = gemini-3.1-flash-lite, 프로덕션 agent 동일 모델):
     { needs_resource: bool,
       category: "shop"|"local"|"blog"|"news"|"web"|"none",
       queries: list[str],
       rationale: str }
     - 모호한 쇼핑/선물은 queries 에 검색 가능한 구체 상품 키워드 여러 개로 분해.
       명확하면 정확한 상품명 1개.
     - category="web" = 네이버 부적합(해외 제품·영어 주제·일반 웹) → Tavily 폴백.
     - needs_resource=false 또는 category="none" → 즉시 none 반환(검색·judge 스킵).
  2. search loop (최대 MAX_ITERS=2):
     - iter 마다 현재 queries 각각을 category 에 맞게 검색:
         naver(shop/local/blog/news): exp4 의 search_naver/_normalize 재사용.
         web: Tavily POST https://api.tavily.com/search.
           TAVILY_API_KEY 없으면 web 검색을 skip 하고 {"_skipped":...} 플래그만 남김
           (전체 중단하지 않음).
     - 수집 결과를 critique(ROUTER_MODEL): { sufficient: bool, new_query: str|None }.
         sufficient=true → loop 종료. 부족하면 new_query 1개로 다음 iter 재검색.
         new_query=None → 종료.
  3. final judge (JUDGE_MODEL = gemini-3.5-flash):
     { useful: bool, usefulness: int 1~5, picked_urls: list[str](최대 3), comment }.
     - useful=false → picked_urls=[] 로 빈손 반환(무용 결과를 내보내지 않는 게이트).

측정 항목 (summary):
  - final_useful_rate : 전체 중 최종 useful=true 비율
  - none_rate         : route 가 needs_resource=false / category=none 으로 끝낸 비율
  - rescue_count      : expect_kind=vague_gift 인데 키워드 추출로 useful 얻은 수
  - refine_count      : loop 가 2회 돈(critique 가 new_query 낸) 케이스 수
  - fallback_used     : web(Tavily) 폴백 실제 호출 케이스 수
  - fallback_skipped  : TAVILY_API_KEY 없어 web 폴백 skip 한 케이스 수
  - suppressed        : final judge 가 useful=false 로 버린 수(false positive 억제)
  - avg_usefulness    : useful=true 케이스의 usefulness 평균
  - avg_iters         : 검색을 돈 케이스의 평균 iter 수

인증 / 키:
  네이버: NAVER_CLIENT_ID, NAVER_CLIENT_SECRET (없으면 sys.exit(1)).
  Gemini: Vertex AI(ADC + GOOGLE_CLOUD_PROJECT).
  Tavily: TAVILY_API_KEY (optional — 없으면 web 폴백만 skip, 전체는 계속).

실행 (repo 루트에서, 키 발급 후):
  GOOGLE_CLOUD_PROJECT=<proj> \\
    NAVER_CLIENT_ID=<id> NAVER_CLIENT_SECRET=<secret> \\
    TAVILY_API_KEY=<tvly> \\
    uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp5_resource_finder_loop.py

결과: results/exp5_YYYYMMDD_HHMMSS.json
      (summary + per-case: route·각 iter 검색결과·critique·final judge)
"""
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import httpx
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"

ROUTER_MODEL = "gemini-3.1-flash-lite"  # route + critique (프로덕션 agent 동일 모델)
JUDGE_MODEL = "gemini-3.5-flash"        # final judge
LOCATION = "global"

NAVER_SEARCH_URL = "https://openapi.naver.com/v1/search/{category}.json"
NAVER_CATEGORIES = ("shop", "local", "blog", "news")
TAVILY_SEARCH_URL = "https://api.tavily.com/search"
DISPLAY = 3            # 검색당 받아올 결과 수
SORT = "sim"           # 네이버: 정확도순
REQUEST_SLEEP = 0.3    # rate limit 배려 — 호출 간 짧은 sleep
MAX_ITERS = 2          # search/critique loop 최대 반복

TAG_RE = re.compile(r"<[^>]+>")  # 네이버 title 의 <b> 등 HTML 태그 strip


ROUTER_PROMPT = (
    "너는 모찌(개인 기억 비서)의 자료 라우터다. 사용자가 저장한 캡처(메모/스크린샷)를 보고, "
    "나중에 이 기록을 다시 볼 때 원문이나 관련 자료로 바로 갈 수 있게 붙여줄 URL 이 필요한지, "
    "필요하다면 어디서·어떤 검색어로 찾을지 라우팅하라.\n"
    "판단 기준은 '사용자가 이 기록을 다시 볼 때 외부 원문/관련 자료로 가고 싶을 만한가' 이다.\n"
    "1) needs_resource: 이 캡처에 관련 URL 을 붙이는 게 사용자에게 도움이 되는가. "
    "친구와의 대화·단순 일정/마감일 메모·할 일 체크처럼 외부 자료가 필요 없는 기록, "
    "또는 단서가 너무 빈약해 무엇을 찾을지조차 정할 수 없는 기록은 false.\n"
    "2) category: 필요하다면 어디서 찾을지 —\n"
    "   - shop : 살까 말까 고민하는 상품(가격·구매로 이어질 것). 국내 커머스.\n"
    "   - local: 가볼 만한 장소·맛집·가게(지도·주소가 핵심).\n"
    "   - blog : 방법·개념·후기처럼 누군가 정리한 정보 글로 알고 싶은 것(국내).\n"
    "   - news : 시사·기사처럼 보도된 뉴스 원문을 다시 찾고 싶은 것.\n"
    "   - web  : 네이버 검색이 부적합한 것 — 해외 제품·영어 주제·국내 검색으로 잘 안 잡히는 "
    "일반 웹 정보. 이 경우 일반 웹검색(Tavily)으로 폴백한다.\n"
    "   - none : 위 어디에도 해당 안 되거나 needs_resource=false 인 경우.\n"
    "3) queries: category 가 none 이 아니면, 그 검색창에 그대로 넣어 좋은 결과가 나올 검색어 리스트.\n"
    "   - raw 검색어가 너무 generic(특정 상품/대상이 아님, 예: '엄마 생신 선물')이면 그대로 검색하지 말고, "
    "검색 가능한 구체 상품 키워드 여러 개로 분해하라(예: ['여성 귀걸이 선물','여성 향수 추천']).\n"
    "   - 대상이 명확하면(예: '아이폰 16 프로 256 자급제') 정확한 상품명/검색어 1개만.\n"
    "   - web 카테고리면 영어/원어 검색어가 더 좋다.\n"
    "   - 마케팅 문구·군더더기는 빼고 핵심 토큰만. none 이면 빈 리스트 [].\n"
    "4) rationale: 왜 그렇게 라우팅했는지(특히 분해/폴백을 택한 이유) 한 줄.\n"
    "needs_resource=false 이면 category 는 none, queries 는 [] 로 둔다."
)


CRITIQUE_PROMPT = (
    "너는 모찌 자료탐색기의 self-critique 단계다. 사용자 캡처와, 지금까지 검색으로 모은 결과 "
    "상위 항목들(제목/링크/요약)을 보고, 이 결과가 캡처에 충분히 관련되고 유용한지 평가하라.\n"
    "- sufficient: 모은 결과가 '사용자가 이 기록을 다시 볼 때 도움이 될 자료' 로 충분한가. "
    "캡처가 가리킨 대상에 잘 맞는 결과가 이미 있으면 true.\n"
    "- new_query: 결과가 부족하지만 검색어를 바꾸면 더 나아질 여지가 있으면, 더 나은 검색어 1개. "
    "이미 충분하거나(sufficient=true), 검색어를 바꿔도 나아질 가망이 없으면 null.\n"
    "검색어를 바꿔도 본질적으로 찾을 게 없으면 무리해서 new_query 를 만들지 말고 null 을 반환하라."
)


JUDGE_PROMPT = (
    "너는 최종 평가자이자 게이트다. 모찌(개인 기억 비서)가 캡처를 보고 자료를 탐색한 뒤 모은 "
    "최종 결과(제목/링크/요약)를 보고, 이걸 사용자에게 '혹시 이거 찾으세요?' 라며 실제로 보여줄 "
    "가치가 있는지 판단하라.\n"
    "- useful: 이 결과 URL 들을 사용자에게 붙여주는 게 정말 도움이 되는가. 캡처가 가리킨 대상과 "
    "동떨어지거나, 단서가 빈약해 추측성 결과만 모였다면 false. 무용한 결과를 내보내지 않는 게 "
    "이 게이트의 목적이다.\n"
    "- usefulness (1-5): 5=캡처가 가리킨 바로 그 자료/상품/장소가 상위에 있음, 3=관련은 있으나 "
    "빗나감, 1=전혀 무관.\n"
    "- picked_urls: useful=true 면, 사용자에게 보여줄 만한 링크를 최대 3개 골라 담아라. "
    "useful=false 면 반드시 빈 리스트 [] 로 둔다.\n"
    "- comment: 한 줄 근거."
)


class Routing(BaseModel):
    needs_resource: bool
    category: str = Field(pattern="^(shop|local|blog|news|web|none)$")
    queries: list[str] = Field(default_factory=list)
    rationale: str


class Critique(BaseModel):
    sufficient: bool
    new_query: str | None = None


class FinalJudge(BaseModel):
    useful: bool
    usefulness: int = Field(ge=1, le=5)
    picked_urls: list[str] = Field(default_factory=list)
    comment: str


# 합성 캡처 케이스 — exp4 의 12 케이스에 expect_kind 라벨(clear|vague_gift|web|none)을
# 붙이고, 키워드 추출·웹폴백·judge 게이트를 자극하는 케이스를 보강해 ~17건.
# expect_kind 는 사람이 결과를 볼 때 참고/집계용 라벨일 뿐, 라우터에는 주지 않는다.
CASES = [
    # exp4 12 케이스 (expect_kind 라벨 부착)
    {"memo": "친구랑 카톡 캡처: 내일 뭐 먹을지 ㅋㅋ", "expect_kind": "none"},
    {"memo": "전세 보증금 안 돌려줌, 소송 절차 알아보기", "expect_kind": "clear"},
    {"memo": "쿠어 스탠드 칼라 넥 다운 푸퍼 검정 살까 말까", "expect_kind": "clear"},
    {"memo": "성수동 분위기 좋은 파스타집 가보기", "expect_kind": "clear"},
    {"memo": "아이폰 16 프로 256 자급제 최저가", "expect_kind": "clear"},
    {"memo": "리액트 서버 컴포넌트 개념 공부하기", "expect_kind": "clear"},
    {"memo": "과제 제출 마감 6월 20일 23:59", "expect_kind": "none"},
    {"memo": "오늘 뉴스에서 본 금리 인하 기사 다시 찾기", "expect_kind": "clear"},
    {"memo": "넷플릭스에서 본 그 요리 다큐 제목 뭐였지", "expect_kind": "none"},
    {"memo": "올리브영에서 본 아비브 어성초 패드 140매", "expect_kind": "clear"},
    {"memo": "엄마 생신 선물 뭐 살지 고민 (아직 안 정함)", "expect_kind": "vague_gift"},
    {"memo": "헬스장 PT 10회권 다음 주 화요일 결제", "expect_kind": "none"},
    # 보강 — 키워드 추출 / 웹폴백 / judge 게이트 자극
    {"memo": "엄마 생신 선물 추천", "expect_kind": "vague_gift"},
    {"memo": "여자친구 화이트데이 선물 뭐 사지", "expect_kind": "vague_gift"},
    {"memo": "신발 예쁜 거 봐둠", "expect_kind": "vague_gift"},
    {"memo": "best mechanical keyboard for programming 2026", "expect_kind": "web"},
    {"memo": "방콕 자유여행 3박4일 추천 코스", "expect_kind": "web"},
    {"memo": "친구가 추천한 그 영화 (제목 기억 안 남)", "expect_kind": "none"},
]


def client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text).strip()


def route(c: genai.Client, memo: str) -> dict:
    """라우터 모델로 캡처를 category + queries(분해 포함)로 라우팅."""
    resp = c.models.generate_content(
        model=ROUTER_MODEL,
        contents=[types.Content(role="user", parts=[
            types.Part.from_text(text=f"사용자 메모: {memo}"),
        ])],
        config=types.GenerateContentConfig(
            system_instruction=ROUTER_PROMPT,
            response_mime_type="application/json",
            response_schema=Routing,
            temperature=0.0,
        ),
    )
    return Routing.model_validate_json(resp.text).model_dump()


def _normalize_item(category: str, it: dict) -> dict:
    """네이버 엔드포인트별로 다른 응답 필드를 정제(분기). exp4 재사용."""
    base = {"title": strip_tags(it.get("title", "")), "link": it.get("link", "")}
    if category == "shop":
        base.update({
            "lprice": it.get("lprice", ""),
            "mallName": it.get("mallName", ""),
            "brand": it.get("brand", ""),
        })
    elif category == "local":
        base.update({
            "category": it.get("category", ""),
            "address": it.get("address", ""),
            "roadAddress": it.get("roadAddress", ""),
        })
    elif category == "blog":
        base.update({
            "description": strip_tags(it.get("description", "")),
            "bloggername": it.get("bloggername", ""),
            "postdate": it.get("postdate", ""),
        })
    elif category == "news":
        base.update({
            "description": strip_tags(it.get("description", "")),
            "pubDate": it.get("pubDate", ""),
        })
    return base


def search_naver(http: httpx.Client, category: str, query: str) -> dict:
    """네이버 검색 API(카테고리별 엔드포인트) 호출 → {total, items} 또는 {error}. exp4 재사용."""
    url = (
        NAVER_SEARCH_URL.format(category=category)
        + f"?query={quote(query)}&display={DISPLAY}&sort={SORT}"
    )
    try:
        resp = http.get(url)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        return {"error": str(e)[:200]}

    items = [_normalize_item(category, it) for it in data.get("items", [])[:DISPLAY]]
    return {"total": data.get("total", 0), "items": items}


def search_tavily(http: httpx.Client, api_key: str, query: str) -> dict:
    """Tavily 웹검색 → {items:[{title,link,description}]} 또는 {error}."""
    try:
        resp = http.post(
            TAVILY_SEARCH_URL,
            json={
                "api_key": api_key,
                "query": query,
                "max_results": DISPLAY,
                "search_depth": "basic",
            },
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        return {"error": str(e)[:200]}

    items = [
        {
            "title": r.get("title", ""),
            "link": r.get("url", ""),
            "description": (r.get("content", "") or "")[:200],
        }
        for r in data.get("results", [])[:DISPLAY]
    ]
    return {"items": items}


def _run_query(
    http: httpx.Client,
    category: str,
    query: str,
    tavily_key: str | None,
) -> dict:
    """category 에 맞게 단일 query 검색. web 인데 키 없으면 skip 플래그."""
    if category == "web":
        if not tavily_key:
            return {"query": query, "_skipped": "no TAVILY_API_KEY"}
        res = search_tavily(http, tavily_key, query)
    else:
        res = search_naver(http, category, query)
    return {"query": query, **res}


def critique(c: genai.Client, memo: str, collected: list[dict]) -> dict:
    """수집 결과가 충분한지 평가 → {sufficient, new_query}."""
    lines = [f"사용자 메모: {memo}", "지금까지 모은 결과:"]
    if collected:
        for i, it in enumerate(collected):
            extra = it.get("description", "")
            lines.append(
                f"  {i+1}. {it.get('title','')} | {it.get('link','')}"
                + (f" — {extra[:80]}" if extra else "")
            )
    else:
        lines.append("  (결과 없음)")
    resp = c.models.generate_content(
        model=ROUTER_MODEL,
        contents=[types.Content(role="user", parts=[
            types.Part.from_text(text="\n".join(lines)),
        ])],
        config=types.GenerateContentConfig(
            system_instruction=CRITIQUE_PROMPT,
            response_mime_type="application/json",
            response_schema=Critique,
            temperature=0.0,
        ),
    )
    return Critique.model_validate_json(resp.text).model_dump()


def final_judge(c: genai.Client, memo: str, routing: dict, collected: list[dict]) -> dict:
    """캡처 + 최종 수집 결과 → useful 게이트 + usefulness + picked_urls."""
    lines = [
        f"사용자 메모: {memo}",
        f"라우터 판단: category={routing['category']}, queries={routing['queries']}",
        "최종 수집 결과:",
    ]
    if collected:
        for i, it in enumerate(collected):
            extra = it.get("description", "")
            lines.append(
                f"  {i+1}. {it.get('title','')} | {it.get('link','')}"
                + (f" — {extra[:80]}" if extra else "")
            )
    else:
        lines.append("  (결과 없음)")
    resp = c.models.generate_content(
        model=JUDGE_MODEL,
        contents=[types.Content(role="user", parts=[
            types.Part.from_text(text="\n".join(lines)),
        ])],
        config=types.GenerateContentConfig(
            system_instruction=JUDGE_PROMPT,
            response_mime_type="application/json",
            response_schema=FinalJudge,
            temperature=0.0,
        ),
    )
    out = FinalJudge.model_validate_json(resp.text).model_dump()
    if not out["useful"]:
        out["picked_urls"] = []  # 게이트: 무용 결과는 빈손
    out["picked_urls"] = out["picked_urls"][:3]
    return out


def _collect_items(searches: list[dict]) -> list[dict]:
    """여러 query 검색 결과에서 items 만 평탄화(skip/error 제외)."""
    items: list[dict] = []
    for s in searches:
        items.extend(s.get("items", []))
    return items


def run_case(
    c: genai.Client,
    http: httpx.Client,
    case: dict,
    tavily_key: str | None,
) -> dict:
    """단일 케이스: route → search/critique loop(≤MAX_ITERS) → final judge."""
    memo = case["memo"]
    row: dict = {"memo": memo, "expect_kind": case["expect_kind"]}

    routing = route(c, memo)
    row["routing"] = routing
    category = routing["category"]

    # none 게이트 — 검색·judge 스킵
    if not routing["needs_resource"] or category == "none":
        row["none"] = True
        row["iters"] = []
        row["final"] = {"useful": False, "usefulness": 1, "picked_urls": [],
                        "comment": "route: needs_resource=false/none"}
        return row

    # search/critique loop
    iters: list[dict] = []
    queries = list(routing["queries"]) or [memo]  # 빈 queries 방어
    collected: list[dict] = []
    web_skipped = False
    web_called = False

    for it_idx in range(MAX_ITERS):
        searches = []
        for q in queries:
            res = _run_query(http, category, q, tavily_key)
            if category == "web":
                if res.get("_skipped"):
                    web_skipped = True
                else:
                    web_called = True
            searches.append(res)
            time.sleep(REQUEST_SLEEP)

        collected = _collect_items(searches)
        crit = critique(c, memo, collected)
        iters.append({"queries": queries, "searches": searches, "critique": crit})

        if crit["sufficient"] or not crit.get("new_query"):
            break
        queries = [crit["new_query"]]  # 다음 iter 는 critique 가 제시한 1개로

    row["iters"] = iters
    row["web_called"] = web_called
    row["web_skipped"] = web_skipped
    row["final"] = final_judge(c, memo, routing, collected)
    return row


def main() -> None:
    cid = os.environ.get("NAVER_CLIENT_ID")
    csecret = os.environ.get("NAVER_CLIENT_SECRET")
    if not cid or not csecret:
        print(
            "네이버 개발자센터에서 검색 API 키 발급 후 "
            "NAVER_CLIENT_ID/NAVER_CLIENT_SECRET 환경변수 설정 필요"
        )
        sys.exit(1)

    tavily_key = os.environ.get("TAVILY_API_KEY")
    if not tavily_key:
        print("[warn] TAVILY_API_KEY 없음 — web 폴백 케이스는 skip 하고 진행")

    c = client()
    naver_headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": csecret,
    }
    print(
        f"케이스 {len(CASES)}건 × "
        f"(route {ROUTER_MODEL} → search/critique loop≤{MAX_ITERS} → final judge {JUDGE_MODEL})"
    )

    results = []
    # 네이버 헤더는 get 에만 필요. Tavily 는 키를 body 로 보내므로 헤더 공유 무방.
    with httpx.Client(headers=naver_headers, timeout=20) as http:
        for case in CASES:
            try:
                row = run_case(c, http, case, tavily_key)
            except Exception as e:  # noqa: BLE001 — 케이스 단위 실패 기록 후 계속
                row = {"memo": case["memo"], "expect_kind": case["expect_kind"],
                       "error": str(e)[:200]}
                results.append(row)
                print(f"  [ERR] {case['memo'][:28]:30s} {row['error'][:50]}")
                continue

            results.append(row)
            cat = row["routing"]["category"]
            qs = row["routing"]["queries"]
            n_iter = len(row.get("iters", []))
            fj = row["final"]
            top = ""
            if not row.get("none"):
                last_items = _collect_items(row["iters"][-1]["searches"]) if row.get("iters") else []
                top = (last_items[0].get("title", "") if last_items else "")
            print(
                f"  [{cat:>5}] {('|'.join(qs))[:30]:32s} → iter={n_iter}, "
                f"useful={fj['useful']}, usefulness={fj['usefulness']}"
                + (f", top={top[:28]}" if top else "")
            )

    # 요약
    ok = [r for r in results if "error" not in r]
    finals = [r["final"] for r in ok if isinstance(r.get("final"), dict)]
    useful = [r for r in ok if r.get("final", {}).get("useful")]
    none_cases = [r for r in ok if r.get("none")]
    searched = [r for r in ok if not r.get("none")]
    rescued = [
        r for r in useful if r["expect_kind"] == "vague_gift"
    ]
    refined = [r for r in searched if len(r.get("iters", [])) >= 2]
    fallback_used = [r for r in searched if r.get("web_called")]
    fallback_skipped = [r for r in searched if r.get("web_skipped")]
    suppressed = [
        r for r in searched if isinstance(r.get("final"), dict) and not r["final"]["useful"]
    ]
    useful_scores = [r["final"]["usefulness"] for r in useful]
    iter_counts = [len(r.get("iters", [])) for r in searched]

    summary = {
        "router_model": ROUTER_MODEL,
        "judge_model": JUDGE_MODEL,
        "cases": len(results),
        "errors": sum(1 for r in results if "error" in r),
        "final_useful_rate": round(len(useful) / max(len(ok), 1), 2),
        "none_rate": round(len(none_cases) / max(len(ok), 1), 2),
        "rescue_count": len(rescued),
        "refine_count": len(refined),
        "fallback_used": len(fallback_used),
        "fallback_skipped": len(fallback_skipped),
        "suppressed": len(suppressed),
        "avg_usefulness": round(sum(useful_scores) / max(len(useful_scores), 1), 2),
        "avg_iters": round(sum(iter_counts) / max(len(iter_counts), 1), 2),
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp5_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
