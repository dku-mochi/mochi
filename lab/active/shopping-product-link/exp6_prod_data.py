"""ResourceFinder loop-agent 실험 (exp6) — exp5 와 동일 loop, 입력만 프로덕션 실데이터.

배경:
  exp5 는 18개 *합성* 메모로 ResourceFinder loop(route → search(naver+tavily 폴백)
  → critique → final judge)를 검증했다. 합성 케이스라 "라우터가 라벨대로 잘 갈리나"
  는 봤지만, 실제 사용자가 저장한 기록 분포에서 키워드 추출·검색 도달성이 통하는지는
  알 수 없었다(데이터 부족 → 실험 정당성 약함).

  exp6 은 loop 구조를 exp5 그대로 두고 **입력만 교체**한다:
    - 하드코딩 CASES(합성 메모) → 프로덕션 DB 추출 mochi_items 97건
      (`lab/data/mochi_items_prod.jsonl`).
    - route 에 넘기는 입력 텍스트를 summary(분석 요약) 중심으로 구성
      ([요약]/[분류]/[메모]/[원본URL]). 캡처 원문(memo) 대신, 모찌가 이미 분석해
      저장해 둔 summary 를 다시 보는 상황 → "이 기록을 나중에 다시 볼 때 원문/관련
      자료로 가고 싶을 만한가" 를 라우터가 판단한다.
    - 실데이터라 정답 라벨(expect_kind)이 없다. final judge 가 절대 평가(useful 여부·
      usefulness 1~5)로 게이트한다.

  검증 질문: 실데이터에서 route 가 summary 를 보고 검색 키워드를 잘 뽑고, 네이버/Tavily
  가 사용자에게 보여줄 만한 URL 을 찾아오는가. 특히 쇼핑 계열 category 가 잘 되는가.

파이프라인 (per case) — exp5 와 동일:
  1. route (ROUTER_MODEL = gemini-3.1-flash-lite):
     { needs_resource, category("shop"|"local"|"blog"|"news"|"web"|"none"),
       queries: list[str], rationale }.
     - generic 하면 검색 가능한 구체 키워드 여러 개로 분해, 명확하면 정확한 검색어 1개.
     - [원본URL]이 이미 충분하면 needs_resource=false 가능(중복 회수 불필요).
     - needs_resource=false / category=none → 검색·judge 스킵.
  2. search loop (≤MAX_ITERS=2) + critique(ROUTER_MODEL):
     naver(shop/local/blog/news) 또는 web(Tavily). TAVILY_API_KEY 없으면 web skip.
     critique: { sufficient, new_query }. 부족하면 new_query 1개로 재검색.
  3. final judge (JUDGE_MODEL = gemini-3.5-flash):
     { useful, usefulness 1~5, picked_urls(≤3), comment }. useful=false → picked_urls=[].

측정 항목 (summary):
  - final_useful_rate : 전체 중 최종 useful=true 비율
  - none_rate         : route 가 needs_resource=false / category=none 으로 끝낸 비율
  - refine_count      : loop 가 2회 돈(critique 가 new_query 낸) 케이스 수
  - fallback_used     : web(Tavily) 폴백 실제 호출 케이스 수
  - fallback_skipped  : TAVILY_API_KEY 없어 web 폴백 skip 한 케이스 수
  - suppressed        : final judge 가 useful=false 로 버린 수(false positive 억제)
  - avg_usefulness    : useful=true 케이스의 usefulness 평균
  - avg_iters         : 검색을 돈 케이스의 평균 iter 수
  - by_category       : 원본 category 별 {cases, useful, useful_rate} — 쇼핑 등이 잘 되는지

인증 / 키:
  네이버: NAVER_CLIENT_ID, NAVER_CLIENT_SECRET (없으면 sys.exit(1)).
  Gemini: Vertex AI(ADC + GOOGLE_CLOUD_PROJECT).
  Tavily: TAVILY_API_KEY (optional — 없으면 web 폴백만 skip, 전체는 계속).

입력:
  lab/data/mochi_items_prod.jsonl — 각 줄 JSON:
    { id, channel, url, summary, category, user_memo }.

실행 (repo 루트에서, 키 발급 후):
  GOOGLE_CLOUD_PROJECT=<proj> \\
    NAVER_CLIENT_ID=<id> NAVER_CLIENT_SECRET=<secret> \\
    TAVILY_API_KEY=<tvly> \\
    uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp6_prod_data.py

결과: results/exp6_YYYYMMDD_HHMMSS.json
      (summary + per-case: orig_summary/category · route · 각 iter 검색결과 · critique · judge)
"""
import json
import os
import re
import sys
import time
from collections import Counter
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
# 입력: 프로덕션 DB 추출 (lab/data 공유 입력, gitignore)
# LAB_ROOT = lab/active/shopping-product-link → parents[1] = lab/
DATA_PATH = LAB_ROOT.parents[1] / "data" / "mochi_items_prod.jsonl"

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
    "너는 모찌(개인 기억 비서)의 자료 라우터다. 사용자가 저장해 둔 기록(모찌가 분석한 "
    "요약/분류와 사용자 메모, 있으면 원본 URL)을 보고, 사용자가 나중에 이 기록을 다시 볼 때 "
    "원문이나 관련 자료로 바로 갈 수 있게 붙여줄 URL 이 필요한지, 필요하다면 어디서·어떤 "
    "검색어로 찾을지 라우팅하라.\n"
    "판단 기준은 '사용자가 이 기록을 다시 볼 때 외부 원문/관련 자료로 가고 싶을 만한가' 이다.\n"
    "1) needs_resource: 이 기록에 관련 URL 을 붙이는 게 사용자에게 도움이 되는가. "
    "친구와의 대화·단순 일정/마감일 메모·할 일 체크처럼 외부 자료가 필요 없는 기록, "
    "또는 단서가 너무 빈약해 무엇을 찾을지조차 정할 수 없는 기록은 false. "
    "[원본URL]이 이미 있고 그것으로 충분하면(중복 회수 불필요) false 도 가능하다.\n"
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
    "너는 모찌 자료탐색기의 self-critique 단계다. 사용자 기록과, 지금까지 검색으로 모은 결과 "
    "상위 항목들(제목/링크/요약)을 보고, 이 결과가 기록에 충분히 관련되고 유용한지 평가하라.\n"
    "- sufficient: 모은 결과가 '사용자가 이 기록을 다시 볼 때 도움이 될 자료' 로 충분한가. "
    "기록이 가리킨 대상에 잘 맞는 결과가 이미 있으면 true.\n"
    "- new_query: 결과가 부족하지만 검색어를 바꾸면 더 나아질 여지가 있으면, 더 나은 검색어 1개. "
    "이미 충분하거나(sufficient=true), 검색어를 바꿔도 나아질 가망이 없으면 null.\n"
    "검색어를 바꿔도 본질적으로 찾을 게 없으면 무리해서 new_query 를 만들지 말고 null 을 반환하라."
)


JUDGE_PROMPT = (
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


def load_cases() -> list[dict]:
    """프로덕션 추출 JSONL → 케이스 리스트. summary 없는 줄은 건너뛴다."""
    cases: list[dict] = []
    with DATA_PATH.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not row.get("summary"):
                continue  # route 입력의 핵심이 summary — 없으면 스킵
            cases.append(row)
    return cases


def build_route_input(row: dict) -> str:
    """route 에 넘기는 입력 텍스트 — summary 중심 + 분류/메모/원본URL(있을 때만)."""
    lines = [f"[요약] {row.get('summary', '')}"]
    if row.get("category"):
        lines.append(f"[분류] {row['category']}")
    if row.get("user_memo"):
        lines.append(f"[메모] {row['user_memo']}")
    if row.get("url"):
        lines.append(f"[원본URL] {row['url']}")
    return "\n".join(lines)


def client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text).strip()


def route(c: genai.Client, route_input: str) -> dict:
    """라우터 모델로 기록(요약 중심)을 category + queries(분해 포함)로 라우팅."""
    resp = c.models.generate_content(
        model=ROUTER_MODEL,
        contents=[types.Content(role="user", parts=[
            types.Part.from_text(text=route_input),
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
    """네이버 엔드포인트별로 다른 응답 필드를 정제(분기). exp5 재사용."""
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
    """네이버 검색 API(카테고리별 엔드포인트) 호출 → {total, items} 또는 {error}. exp5 재사용."""
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
    """Tavily 웹검색 → {items:[{title,link,description}]} 또는 {error}. exp5 재사용."""
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
    """category 에 맞게 단일 query 검색. web 인데 키 없으면 skip 플래그. exp5 재사용."""
    if category == "web":
        if not tavily_key:
            return {"query": query, "_skipped": "no TAVILY_API_KEY"}
        res = search_tavily(http, tavily_key, query)
    else:
        res = search_naver(http, category, query)
    return {"query": query, **res}


def critique(c: genai.Client, route_input: str, collected: list[dict]) -> dict:
    """수집 결과가 충분한지 평가 → {sufficient, new_query}. exp5 재사용."""
    lines = [f"사용자 기록:\n{route_input}", "지금까지 모은 결과:"]
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


def final_judge(c: genai.Client, route_input: str, routing: dict, collected: list[dict]) -> dict:
    """기록 + 최종 수집 결과 → useful 게이트 + usefulness + picked_urls. exp5 재사용."""
    lines = [
        f"사용자 기록:\n{route_input}",
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
    """여러 query 검색 결과에서 items 만 평탄화(skip/error 제외). exp5 재사용."""
    items: list[dict] = []
    for s in searches:
        items.extend(s.get("items", []))
    return items


def _top3(searches: list[dict]) -> list[dict]:
    """엔드포인트별 top3 title+link 만 추려 per-case 보고에 담는다."""
    out: list[dict] = []
    for s in searches:
        for it in s.get("items", [])[:3]:
            out.append({"title": it.get("title", ""), "link": it.get("link", "")})
    return out


def run_case(
    c: genai.Client,
    http: httpx.Client,
    case: dict,
    tavily_key: str | None,
) -> dict:
    """단일 케이스: route → search/critique loop(≤MAX_ITERS) → final judge."""
    cid = case["id"][:8]
    route_input = build_route_input(case)
    row: dict = {
        "id": cid,
        "orig_summary": case.get("summary", ""),
        "orig_category": case.get("category"),
        "orig_url": case.get("url"),
    }

    routing = route(c, route_input)
    row["route"] = routing
    category = routing["category"]

    # none 게이트 — 검색·judge 스킵
    if not routing["needs_resource"] or category == "none":
        row["none"] = True
        row["iters"] = []
        row["searched_results"] = []
        row["critique"] = None
        row["judge"] = {"useful": False, "usefulness": 1, "picked_urls": [],
                        "comment": "route: needs_resource=false/none"}
        return row

    # search/critique loop
    iters: list[dict] = []
    queries = list(routing["queries"]) or [route_input[:60]]  # 빈 queries 방어
    collected: list[dict] = []
    last_critique: dict | None = None
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
        crit = critique(c, route_input, collected)
        last_critique = crit
        iters.append({"queries": queries, "searches": searches, "critique": crit})

        if crit["sufficient"] or not crit.get("new_query"):
            break
        queries = [crit["new_query"]]  # 다음 iter 는 critique 가 제시한 1개로

    row["iters"] = iters
    row["web_called"] = web_called
    row["web_skipped"] = web_skipped
    # 추적용: 마지막 iter 의 엔드포인트별 top3 + 최종 critique
    row["searched_results"] = _top3(iters[-1]["searches"]) if iters else []
    row["critique"] = last_critique
    row["judge"] = final_judge(c, route_input, routing, collected)
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

    cases = load_cases()
    c = client()
    naver_headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": csecret,
    }
    print(
        f"프로덕션 케이스 {len(cases)}건 × "
        f"(route {ROUTER_MODEL} → search/critique loop≤{MAX_ITERS} → final judge {JUDGE_MODEL})"
    )

    results = []
    # 네이버 헤더는 get 에만 필요. Tavily 는 키를 body 로 보내므로 헤더 공유 무방.
    with httpx.Client(headers=naver_headers, timeout=20) as http:
        for idx, case in enumerate(cases):
            cid8 = case["id"][:8]
            try:
                row = run_case(c, http, case, tavily_key)
            except Exception as e:  # noqa: BLE001 — 케이스 단위 실패 기록 후 계속
                row = {
                    "id": cid8,
                    "orig_summary": case.get("summary", ""),
                    "orig_category": case.get("category"),
                    "error": str(e)[:200],
                }
                results.append(row)
                print(f"  [{idx+1}/{len(cases)}] [ERR] {cid8} {row['error'][:50]}")
                continue

            results.append(row)
            orig_cat = row.get("orig_category") or "-"
            rcat = row["route"]["category"]
            qs = row["route"]["queries"]
            fj = row["judge"]
            top = ""
            if not row.get("none"):
                sr = row.get("searched_results", [])
                top = sr[0]["title"] if sr else ""
            print(
                f"  [{idx+1}/{len(cases)}] [{str(orig_cat)[:8]:>8}|{rcat:>5}] "
                f"{('|'.join(qs))[:28]:30s} → useful={fj['useful']}, "
                f"usefulness={fj['usefulness']}"
                + (f", top={top[:24]}" if top else "")
            )

    # 요약
    ok = [r for r in results if "error" not in r]
    useful = [r for r in ok if r.get("judge", {}).get("useful")]
    none_cases = [r for r in ok if r.get("none")]
    searched = [r for r in ok if not r.get("none")]
    refined = [r for r in searched if len(r.get("iters", [])) >= 2]
    fallback_used = [r for r in searched if r.get("web_called")]
    fallback_skipped = [r for r in searched if r.get("web_skipped")]
    suppressed = [
        r for r in searched if isinstance(r.get("judge"), dict) and not r["judge"]["useful"]
    ]
    useful_scores = [r["judge"]["usefulness"] for r in useful]
    iter_counts = [len(r.get("iters", [])) for r in searched]

    # 원본 category 별 useful 분포 — 쇼핑 계열이 잘 되는지
    cat_total = Counter(str(r.get("orig_category")) for r in ok)
    cat_useful = Counter(str(r.get("orig_category")) for r in useful)
    by_category = {
        cat: {
            "cases": cat_total[cat],
            "useful": cat_useful.get(cat, 0),
            "useful_rate": round(cat_useful.get(cat, 0) / max(cat_total[cat], 1), 2),
        }
        for cat in sorted(cat_total, key=lambda k: -cat_total[k])
    }

    summary = {
        "router_model": ROUTER_MODEL,
        "judge_model": JUDGE_MODEL,
        "data": str(DATA_PATH.name),
        "cases": len(results),
        "errors": sum(1 for r in results if "error" in r),
        "final_useful_rate": round(len(useful) / max(len(ok), 1), 2),
        "none_rate": round(len(none_cases) / max(len(ok), 1), 2),
        "refine_count": len(refined),
        "fallback_used": len(fallback_used),
        "fallback_skipped": len(fallback_skipped),
        "suppressed": len(suppressed),
        "avg_usefulness": round(sum(useful_scores) / max(len(useful_scores), 1), 2),
        "avg_iters": round(sum(iter_counts) / max(len(iter_counts), 1), 2),
        "by_category": by_category,
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp6_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
