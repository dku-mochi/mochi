"""네이버 검색 API 범용 백본 실험 (exp4) — 임의 캡처 → 카테고리 라우팅 → 실재 URL.

배경:
  exp1~3 은 *쇼핑* 단일 도메인이었다(캡처에서 상품 식별 → 네이버 쇼핑 검색 API
  실재성). exp4 는 이를 일반화한다: 네이버 검색 API(shop/local/blog/news)가
  모찌의 "이 기록에 붙일 관련 URL" 을 찾는 *범용 백본* 으로 쓸 수 있는가.

  핵심 가설:
    임의의 캡처(메모/스크린샷)에 대해 LLM 이
      (1) URL 이 필요한지 판단하고(needs_resource),
      (2) 필요하면 적절한 네이버 검색 카테고리 + 검색어로 라우팅하면,
    실재하고 유용한 URL 이 나온다.
  이게 참이면 프로덕션 메인 agent loop 의 tool(`ResourceFinderTool`)로 넣는다.

파이프라인 (per case):
  1. 라우팅 (ROUTER_MODEL = gemini-3.1-flash-lite, 프로덕션 agent 동일 모델):
     캡처 텍스트를 보고 구조화 출력
       { needs_resource: bool,
         category: "shop"|"local"|"blog"|"news"|"none",
         query: str|None,
         reason: str }
     - needs_resource=false 또는 category="none" → URL 불필요(친구 대화·단순
       마감일 메모 등). query=None.
     - 라우팅 기준: "사용자가 이 기록을 다시 볼 때 원문/관련 자료로 가고 싶을
       만한가, 그렇다면 어느 종류(상품 검색/장소/정보 글/뉴스)인가."
  2. 검색: category != none 이면 해당 네이버 엔드포인트 호출(display=3, sort=sim).
     엔드포인트마다 응답 필드가 다르므로 카테고리별로 분기 정제한다.
  3. judge (JUDGE_MODEL = gemini-3.5-flash, Vertex AI, temperature=0.0):
     캡처 + 라우팅 결과 + 검색 상위 3개(title/link)를 보고
       { routing_ok: bool(라우팅 카테고리·needs 판단이 적절한가),
         usefulness: int 1~5("혹시 이거 찾으세요?" 로 이 URL 들을 줄 만한가),
         comment: str }
     - needs_resource=false 케이스는 검색·usefulness 를 건너뛰고 routing_ok 만
       judge(불필요 판단이 맞았나). 토큰 절약.

측정 항목 (summary):
  - routing_ok_rate   = judge.routing_ok=true 비율 (전체 케이스)
  - none_rate         = 라우터가 needs_resource=false / category=none 으로 본 비율
  - found_rate        = 검색을 한 케이스 중 total>0 비율
  - avg_usefulness    = 검색한 케이스의 judge.usefulness 평균

네이버 엔드포인트별 응답 필드 (엔드포인트마다 다름 — 카테고리별 분기):
  - shop.json:  items[].{title, link, image, lprice, mallName, brand, category1~4}
  - local.json: items[].{title, link, category, description, address, roadAddress, mapx, mapy}
  - blog.json:  items[].{title, link, description, bloggername, postdate}
  - news.json:  items[].{title, link, description, pubDate}
  공통: title 에 <b> 등 HTML 태그 포함 가능 → 태그 strip.
  엔드포인트: https://openapi.naver.com/v1/search/{category}.json

인증 / 키:
  네이버 개발자센터(https://developers.naver.com)에서 "검색" API 등록 →
  Client ID/Secret 발급 후 환경변수:
    NAVER_CLIENT_ID, NAVER_CLIENT_SECRET
  Gemini judge/router 는 exp1~3 과 동일하게 Vertex AI(ADC + GOOGLE_CLOUD_PROJECT).

실행 (repo 루트에서, 키 발급 후):
  GOOGLE_CLOUD_PROJECT=<proj> \\
    NAVER_CLIENT_ID=<id> NAVER_CLIENT_SECRET=<secret> \\
    uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp4_universal_router.py

결과: results/exp4_YYYYMMDD_HHMMSS.json (summary + per-case 라우팅·검색 top3·judge)
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

ROUTER_MODEL = "gemini-3.1-flash-lite"  # 프로덕션 agent 동일 모델
JUDGE_MODEL = "gemini-3.5-flash"
LOCATION = "global"

NAVER_SEARCH_URL = "https://openapi.naver.com/v1/search/{category}.json"
CATEGORIES = ("shop", "local", "blog", "news")
DISPLAY = 3            # 카테고리당 받아올 결과 수
SORT = "sim"           # 정확도순
REQUEST_SLEEP = 0.3    # rate limit 배려 — query 간 짧은 sleep

TAG_RE = re.compile(r"<[^>]+>")  # 네이버 title 의 <b> 등 HTML 태그 strip


ROUTER_PROMPT = (
    "너는 모찌(개인 기억 비서)의 자료 라우터다. 사용자가 저장한 캡처(메모/스크린샷)를 보고, "
    "나중에 이 기록을 다시 볼 때 원문이나 관련 자료로 바로 갈 수 있게 붙여줄 URL 이 필요한지, "
    "필요하다면 네이버 검색의 어느 종류로 찾을지 라우팅하라.\n"
    "판단 기준은 '사용자가 이 기록을 다시 볼 때 외부 원문/관련 자료로 가고 싶을 만한가' 이다.\n"
    "1) needs_resource: 이 캡처에 관련 URL 을 붙이는 게 사용자에게 도움이 되는가. "
    "친구와의 대화·단순 일정/마감일 메모·할 일 체크처럼 외부 자료가 필요 없는 기록은 false.\n"
    "2) category: 필요하다면 어디서 찾을지 —\n"
    "   - shop : 살까 말까 고민하는 상품(가격·구매로 이어질 것).\n"
    "   - local: 가볼 만한 장소·맛집·가게(지도·주소가 핵심).\n"
    "   - blog : 방법·개념·후기처럼 누군가 정리한 정보 글로 알고 싶은 것.\n"
    "   - news : 시사·기사처럼 보도된 뉴스 원문을 다시 찾고 싶은 것.\n"
    "   - none : 위 어디에도 해당 안 되거나 needs_resource=false 인 경우.\n"
    "3) query: category 가 none 이 아니면, 그 검색창에 그대로 넣어 좋은 결과가 나올 한국어 검색어. "
    "마케팅 문구·군더더기는 빼고 핵심 토큰만. none 이면 null.\n"
    "4) reason: 왜 그렇게 라우팅했는지 한 줄.\n"
    "needs_resource=false 이면 category 는 none, query 는 null 로 둔다."
)


JUDGE_PROMPT = (
    "너는 평가자다. 모찌(개인 기억 비서)가 캡처를 보고 (1) 관련 URL 이 필요한지·어느 카테고리로 "
    "찾을지 라우팅한 결과와, (2) 그 라우팅대로 네이버 검색을 친 상위 결과(제목/링크)를 보고 채점하라.\n"
    "- routing_ok: 라우터의 판단(needs_resource·category)이 이 캡처에 적절했는가. "
    "외부 자료가 필요 없는 기록을 불필요(needs_resource=false)로 본 것도 적절한 라우팅이다. "
    "반대로, 자료가 도움이 될 캡처를 불필요로 흘려보냈거나 엉뚱한 카테고리를 고르면 false.\n"
    "- usefulness (1-5): 이 검색 결과 URL 들을 사용자에게 '혹시 이거 찾으세요?' 라며 보여줄 만한가. "
    "5=캡처가 가리킨 바로 그 자료/상품/장소가 상위에 있음, 3=관련은 있으나 빗나감, 1=전혀 무관.\n"
    "- comment: 한 줄 근거.\n"
    "검색을 하지 않은(needs_resource=false) 케이스는 usefulness 를 1 로 두고 routing_ok 만 판단하라."
)


class Routing(BaseModel):
    needs_resource: bool
    category: str = Field(pattern="^(shop|local|blog|news|none)$")
    query: str | None = None
    reason: str


class JudgeScore(BaseModel):
    routing_ok: bool
    usefulness: int = Field(ge=1, le=5)
    comment: str


# 합성 캡처 케이스 — 도메인 다양성이 핵심. expect_category 는 사람이 결과를 볼 때
# 참고하는 라벨일 뿐, 라우터에는 주지 않는다(라우터는 memo 만 본다).
CASES = [
    {"memo": "친구랑 카톡 캡처: 내일 뭐 먹을지 ㅋㅋ", "expect_category": "none"},
    {"memo": "전세 보증금 안 돌려줌, 소송 절차 알아보기", "expect_category": "blog"},
    {"memo": "쿠어 스탠드 칼라 넥 다운 푸퍼 검정 살까 말까", "expect_category": "shop"},
    {"memo": "성수동 분위기 좋은 파스타집 가보기", "expect_category": "local"},
    {"memo": "아이폰 16 프로 256 자급제 최저가", "expect_category": "shop"},
    {"memo": "리액트 서버 컴포넌트 개념 공부하기", "expect_category": "blog"},
    {"memo": "과제 제출 마감 6월 20일 23:59", "expect_category": "none"},
    {"memo": "오늘 뉴스에서 본 금리 인하 기사 다시 찾기", "expect_category": "news"},
    {"memo": "넷플릭스에서 본 그 요리 다큐 제목 뭐였지", "expect_category": "none/blog"},
    {"memo": "올리브영에서 본 아비브 어성초 패드 140매", "expect_category": "shop"},
    # 비URL 음성 케이스 보강
    {"memo": "엄마 생신 선물 뭐 살지 고민 (아직 안 정함)", "expect_category": "none"},
    {"memo": "헬스장 PT 10회권 다음 주 화요일 결제", "expect_category": "none"},
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
    """라우터 모델로 캡처를 카테고리+검색어로 라우팅."""
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
    """엔드포인트별로 다른 응답 필드를 케이스 기록·judge 용으로 정제(분기)."""
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
    """네이버 검색 API(카테고리별 엔드포인트) 호출 → {total, items} 또는 {error}."""
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


def judge(c: genai.Client, memo: str, routing: dict, search: dict | None) -> dict:
    """캡처 + 라우팅 + 검색 top3 을 보고 routing_ok·usefulness 채점."""
    lines = [
        f"사용자 메모: {memo}",
        f"라우터 판단: {json.dumps(routing, ensure_ascii=False)}",
    ]
    if search and search.get("items"):
        lines.append(f"네이버 '{routing['category']}' 검색 상위 {len(search['items'])}개:")
        for i, it in enumerate(search["items"]):
            lines.append(f"  {i+1}. {it['title']} | {it['link']}")
    else:
        lines.append("(검색하지 않음 — 라우터가 자료 불필요로 판단)")
    resp = c.models.generate_content(
        model=JUDGE_MODEL,
        contents=[types.Content(role="user", parts=[
            types.Part.from_text(text="\n".join(lines)),
        ])],
        config=types.GenerateContentConfig(
            system_instruction=JUDGE_PROMPT,
            response_mime_type="application/json",
            response_schema=JudgeScore,
            temperature=0.0,
        ),
    )
    return JudgeScore.model_validate_json(resp.text).model_dump()


def main() -> None:
    cid = os.environ.get("NAVER_CLIENT_ID")
    csecret = os.environ.get("NAVER_CLIENT_SECRET")
    if not cid or not csecret:
        print(
            "네이버 개발자센터에서 검색 API 키 발급 후 "
            "NAVER_CLIENT_ID/NAVER_CLIENT_SECRET 환경변수 설정 필요"
        )
        sys.exit(1)

    c = client()
    naver_headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": csecret,
    }
    print(f"케이스 {len(CASES)}건 × (라우팅 {ROUTER_MODEL} → 네이버 검색 → judge {JUDGE_MODEL})")

    results = []
    with httpx.Client(headers=naver_headers, timeout=15) as http:
        for case in CASES:
            memo = case["memo"]
            row: dict = {"memo": memo, "expect_category": case["expect_category"]}

            try:
                routing = route(c, memo)
            except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
                row["error"] = f"route: {str(e)[:160]}"
                results.append(row)
                print(f"  [ERR] {memo[:30]:32s} {row['error'][:50]}")
                continue
            row["routing"] = routing

            search = None
            category = routing["category"]
            if routing["needs_resource"] and category != "none" and routing["query"]:
                search = search_naver(http, category, routing["query"])
                if "error" in search:
                    row["search_error"] = search["error"]
                    search = None
                else:
                    row["search"] = search
                time.sleep(REQUEST_SLEEP)

            try:
                row["judge"] = judge(c, memo, routing, search)
            except Exception as e:  # noqa: BLE001
                row["judge"] = {"error": str(e)[:200]}

            results.append(row)
            total = (search or {}).get("total", "-")
            top1 = ((search or {}).get("items") or [{}])[0].get("title", "")
            q = routing["query"] or ""
            print(
                f"  [{category:>5}] {q[:24]:26s} → total={total}"
                + (f", top1={top1[:32]}" if top1 else "")
            )

    # 요약
    ok = [r for r in results if "error" not in r]
    judged = [
        r["judge"] for r in ok
        if isinstance(r.get("judge"), dict) and "error" not in r["judge"]
    ]
    none_cases = [
        r for r in ok
        if not r["routing"]["needs_resource"] or r["routing"]["category"] == "none"
    ]
    searched = [r for r in ok if isinstance(r.get("search"), dict)]
    found = [r for r in searched if r["search"].get("total", 0) > 0]
    searched_judged = [
        r["judge"] for r in searched
        if isinstance(r.get("judge"), dict) and "error" not in r["judge"]
    ]
    summary = {
        "router_model": ROUTER_MODEL,
        "judge_model": JUDGE_MODEL,
        "cases": len(results),
        "errors": sum(1 for r in results if "error" in r),
        "routing_ok_rate": round(
            sum(1 for j in judged if j["routing_ok"]) / max(len(judged), 1), 2
        ),
        "none_rate": round(len(none_cases) / max(len(ok), 1), 2),
        "searched": len(searched),
        "found_rate": round(len(found) / max(len(searched), 1), 2),
        "avg_usefulness": round(
            sum(j["usefulness"] for j in searched_judged) / max(len(searched_judged), 1), 2
        ),
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp4_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
