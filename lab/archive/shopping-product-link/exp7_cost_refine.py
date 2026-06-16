"""쇼핑/자료 라우터 약점 개선 + 비용 측정 실험 (exp7) — exp6 의 실패 케이스만 재실험.

배경:
  exp6 은 프로덕션 97건으로 ResourceFinder loop(route → search(naver/tavily) → critique
  → final judge)를 돌려 final_useful_rate=0.48 을 얻었다. 실패 패턴이 뚜렷했다:
    - 추천/목록형 캡처("육아템 추천","보온병 추천","남성 약산성 세안제 추천")를 shop 으로
      raw 검색 → 특정 상품이 없어 무관 결과만, judge 가 전부 suppress.
    - generic 키워드("살림 꿀템","키보드 추천")를 그대로 shop 검색 → 일반 추천 상품만.
    - 일반명사화 브랜드(LUCIER 안경) → 저가 뿔테안경만, 식별자(인물/모델) 누락.
    - local 군더더기("동탄 모프 미용실 가는 길") → 검색 0건.
    - 판매단위/프로모션 토큰("...2입 기획")이 검색을 과도하게 좁힘.

  exp7 은 loop 구조·critique/judge 프롬프트는 exp6 그대로 두고 **세 가지만** 바꾼다:
    1. 대상 한정: exp6 결과에서 "검색을 돌렸으나 실패(useful=false)하거나 빗나간
       (usefulness<=3)" 케이스만 재실험. none/검색불필요는 제외(개선 대상 아님).
       exp6 의 before(useful/usefulness/queries/comment)를 per-case 에 같이 남겨 직접 비교.
    2. ROUTER_PROMPT 개선: 추천/목록형·local 군더더기·프로모션 토큰·일반명사화 브랜드의
       4개 실패 패턴을 프롬프트 기준으로 명시(아래 ROUTER_PROMPT 주석 참조).
    3. 비용 측정: 서버 구현(app.shared.llm_usage / llm_cost)을 그대로 재사용해
       route/critique/judge 의 토큰 사용량·USD 를 케이스별·단계별·모델별로 집계.

  검증 질문: 개선된 라우터가 exp6 의 실패 케이스를 얼마나 살리는가(improved/regressed/
  still_failing), 그리고 케이스당 LLM 비용은 얼마인가.

대상 선별 (exp6 결과에서 타겟 추출):
  타겟 = not none and "error" not in r and (judge.useful==False or judge.usefulness<=3).
  각 타겟의 id(8자 prefix)로 mochi_items_prod.jsonl 의 원본 row(full UUID)를 prefix 매칭.

측정 항목 (summary) — exp6 지표 + 개선 비교 + 비용:
  - final_useful_rate / avg_usefulness / suppressed / refine_count ... (exp6 와 동일 산식)
  - improved   : before useful=false → after useful=true 수
  - regressed  : before useful=true  → after useful=false 수
  - still_failing : before·after 모두 useful=false 수
  - exp6_useful_rate / useful_rate_delta : 타겟 부분집합 기준 before→after 변화
  - total_cost_usd / avg_cost_per_case_usd : LLM 비용(Tavily 별도)
  - cost_by_step  : route/critique/judge 단계별 USD 합
  - cost_by_model : 모델별 USD 합
  - tavily_calls  : web 폴백 실제 호출 수(별도 과금원 — 호출 수만, USD 환산은 안 함)
  - tier_distribution : 액션티어 랭킹의 보여준 1순위(ranked top1) tier_label 분포.
  - original_match_count : tier 0(캡처 [원본URL] 도메인 일치) 발동 수.

액션티어 랭킹 (결정적, LLM 호출 추가 없음 → 비용 불변):
  judge 가 useful=true 일 때, judge 가 고른 candidate 를 classify_tier 로 재정렬해
  ranked_urls(top3) 산출. tier=액션가능성+정확성(0 원본 / 1 공식 / 2 편집샵 /
  3 오픈마켓·직구·가격비교 / 4 정보). judge 의 관련성 필터는 유지(useful=false→빈손).

비용 측정 방식 (서버 구현 재사용, 복붙 금지):
  - sys.path 에 mochi-backend 추가 후 from app.shared.llm_usage import extract_token_usage,
    from app.shared.llm_cost import estimate_cost_usd.
  - generate_content 응답을 받은 직후 extract_token_usage(resp)로 (tin, tout) 추출,
    estimate_cost_usd(model, tin, tout)로 USD(Decimal). 단가표에 없는 모델은 None.
  - 케이스별 usage{route, critique, judge}, case_cost_usd(합), 전역 누적 모두 기록.

인증 / 키 (exp6 와 동일):
  네이버: NAVER_CLIENT_ID, NAVER_CLIENT_SECRET (없으면 sys.exit(1)).
  Gemini: Vertex AI(ADC + GOOGLE_CLOUD_PROJECT).
  Tavily: TAVILY_API_KEY (optional — 없으면 web 폴백만 skip).

입력:
  results/exp6_*.json (최신) — 재실험 타겟 + before 결과 출처.
  lab/data/mochi_items_prod.jsonl — 타겟 원본 row(summary/category/url/user_memo).

실행 (repo 루트에서, 키 발급 후):
  GOOGLE_CLOUD_PROJECT=<proj> \\
    NAVER_CLIENT_ID=<id> NAVER_CLIENT_SECRET=<secret> \\
    TAVILY_API_KEY=<tvly> \\
    uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp7_cost_refine.py

결과: results/exp7_YYYYMMDD_HHMMSS.json
      (summary[exp6 지표 + 개선 비교 + 비용 + 티어분포] + per-case[before/after + route/
       queries/searched_results/judge + ranked_urls(액션티어 정렬) + usage/cost])
"""
import glob
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from urllib.parse import quote, urlparse

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

# 비용 측정: 서버 구현 재사용(복붙 금지). LAB_ROOT.parents[2] = repo 루트 → mochi-backend.
sys.path.insert(0, str(LAB_ROOT.parents[2] / "mochi-backend"))
from app.shared.llm_cost import estimate_cost_usd  # noqa: E402
from app.shared.llm_usage import extract_token_usage  # noqa: E402

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


# ── 액션티어 랭킹 (결정적, LLM 아님) ─────────────────────────────────────────
# tier = "들어가서 바로 액션(예약/구매/시청)이 되는가 + 정확한가" 의 점수.
#   route category 가 "어떤 종류 액션" 인지는 이미 정했으니, 같은 결과군 안에서
#   이 티어로 결정적 정렬한다(LLM 호출 추가 없음 → 비용 불변). tier 작을수록 우선.
# 좁은 예시 암기가 목적이 아니라 '액션가능성 + 정확성' 기준의 인스턴스다:
#   0 원본일치 / 1 공식(직접운영, 바로 액션+정확) / 2 편집샵(큐레이션 커머스)
#   3 오픈마켓·직구·가격비교(액션은 되나 정확·최저가 보장 약함, sub-rank)
#   4 정보(참고만, 액션 불가) / default: shop 미매칭→3.0, web/blog 미매칭→4.
# DOMAIN_TIER: link netloc 안에서 substring 매칭할 도메인 키 → tier.
DOMAIN_TIER: dict[str, float] = {
    # tier 1 — 공식(브랜드/서비스 직접 운영, 들어가면 바로 예약/구매/시청 + 정확)
    "netflix.com": 1.0,
    "youtube.com": 1.0,
    "youtu.be": 1.0,
    "map.naver.com": 1.0,
    "place.naver.com": 1.0,
    "lottecinema.com": 1.0,
    "cgv.co.kr": 1.0,
    "megabox.co.kr": 1.0,
    "myrealtrip.com": 1.0,
    "catchtable.co.kr": 1.0,
    # tier 2 — 편집샵(큐레이션 커머스, 액션 가능)
    "oliveyoung": 2.0,
    "musinsa": 2.0,
    "29cm": 2.0,
    "wconcept": 2.0,
    "zigzag": 2.0,
    "kream": 2.0,
    "ably": 2.0,
    "brandi": 2.0,
    # tier 3 — 오픈마켓/직구/가격비교(액션 O, 정확·최저가 보장 약함). sub-rank:
    "coupang": 3.0,                       # 3.0 오픈마켓
    "smartstore.naver.com": 3.0,          # 3.0 스마트스토어
    "aliexpress": 3.3,                    # 3.3 해외직구
    "temu": 3.3,
    "11st": 3.6,                          # 3.6 가격비교/마이너
    "gmarket": 3.6,
    "auction": 3.6,
    "danawa": 3.6,
    "google": 3.6,                        # 구글쇼핑
    "search.shopping.naver.com/catalog": 3.6,  # 네이버 가격비교 catalog
    # tier 4 — 정보(참고만, 액션 불가)
    "blog.naver.com": 4.0,
    "tistory.com": 4.0,
    "brunch.co.kr": 4.0,
    "medium.com": 4.0,
    "velog.io": 4.0,
}
# MALL_TIER: 네이버 shop 결과의 mallName 부분문자열 매칭 → tier. shop 은 mallName 우선.
MALL_TIER: dict[str, float] = {
    # tier 2 — 편집샵(한글 mallName 포함)
    "올리브영": 2.0,
    "무신사": 2.0,
    "29cm": 2.0,
    "에이블리": 2.0,
    "브랜디": 2.0,
    # tier 3 — 오픈마켓/직구/가격비교 (mallName 으로 들어오는 것들)
    "쿠팡": 3.0,
    "스마트스토어": 3.0,
    "알리": 3.3,
    "테무": 3.3,
    "11번가": 3.6,
    "지마켓": 3.6,
    "옥션": 3.6,
    "다나와": 3.6,
}
TIER_LABEL = {
    0.0: "tier0_original",
    1.0: "tier1_official",
    2.0: "tier2_editorial",
    3.0: "tier3_openmarket",
    3.3: "tier3_overseas",
    3.6: "tier3_pricecompare",
    4.0: "tier4_info",
}


def _host(url: str) -> str:
    """url netloc 에서 'www.' 제거한 호스트(소문자). 경로 포함 매칭을 위해 path 도 붙여 반환."""
    try:
        p = urlparse(url)
    except Exception:  # noqa: BLE001 — 실험: 파싱 실패는 빈 host
        return ""
    host = (p.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    # search.shopping.naver.com/catalog 같은 path 포함 키 매칭을 위해 path 도 결합
    return host + (p.path or "").lower()


def classify_tier(item: dict, route_category: str, case_url: str | None) -> dict:
    """결과 1개의 액션티어 산출 → {tier_num, tier_label, signal}.

    - shop: mallName 우선, 없으면 link 도메인. local/web/blog/news: link 도메인.
    - case_url(캡처 [원본URL]) 과 도메인 일치 → tier 0(원본일치, 무조건 최상위).
    - 매칭 실패 default: shop → 3.0(오픈마켓 보수적 가정), 그 외 → 4(정보).
    tier=액션가능성+정확성 기준. 작을수록 우선.
    """
    link = item.get("link", "") or ""
    host = _host(link)

    # tier 0 — 원본일치: 캡처 원문과 같은 도메인이면 무조건 최상위
    if case_url:
        case_host = _host(case_url)
        # netloc 부분(첫 path segment 이전)만 비교
        case_netloc = case_host.split("/")[0]
        link_netloc = host.split("/")[0]
        if case_netloc and link_netloc and case_netloc == link_netloc:
            return {"tier_num": 0.0, "tier_label": TIER_LABEL[0.0], "signal": case_netloc}

    # shop 은 mallName 신호 우선
    if route_category == "shop":
        mall = (item.get("mallName", "") or "")
        for key, tier in MALL_TIER.items():
            if key in mall:
                return {"tier_num": tier, "tier_label": TIER_LABEL[tier], "signal": f"mall:{key}"}

    # 도메인 substring 매칭(공통 — shop/local/web/blog/news)
    for key, tier in DOMAIN_TIER.items():
        if key in host:
            return {"tier_num": tier, "tier_label": TIER_LABEL[tier], "signal": f"domain:{key}"}

    # default — 모르는 신호: shop 은 오픈마켓(3.0) 보수적 가정, 그 외는 정보(4)
    if route_category == "shop":
        return {"tier_num": 3.0, "tier_label": TIER_LABEL[3.0], "signal": "default:shop"}
    return {"tier_num": 4.0, "tier_label": TIER_LABEL[4.0], "signal": "default:info"}


def rank_results(
    judge: dict, collected: list[dict], route_category: str, case_url: str | None
) -> list[dict]:
    """useful=true 인 judge 의 채택군을 액션티어로 결정적 정렬 → top3 ranked_urls.

    candidate = judge.picked_urls 에 매칭되는 collected item(매칭 0건이면 collected 전체).
    정렬 키: (tier_num asc, 기존 검색 등장 순서). useful=false 면 빈 리스트(게이트 유지).
    반환 원소: {url, title, tier_num, tier_label, signal}.
    """
    if not judge.get("useful"):
        return []
    picked = set(judge.get("picked_urls") or [])
    if picked:
        candidates = [it for it in collected if (it.get("link", "") in picked)]
        if not candidates:  # picked URL 이 collected 와 안 맞으면 collected 전체로
            candidates = list(collected)
    else:
        candidates = list(collected)

    ranked = []
    for order, it in enumerate(candidates):
        t = classify_tier(it, route_category, case_url)
        ranked.append((t["tier_num"], order, it, t))
    ranked.sort(key=lambda x: (x[0], x[1]))  # tier asc, then 등장 순서
    return [
        {
            "url": it.get("link", ""),
            "title": it.get("title", ""),
            "tier_num": t["tier_num"],
            "tier_label": t["tier_label"],
            "signal": t["signal"],
        }
        for _tier, _order, it, t in ranked[:3]
    ]


# ROUTER_PROMPT — exp6 대비 개선판. critique/judge 프롬프트는 exp6 그대로 둔다.
# exp6 실패 패턴을 "예시 나열" 이 아니라 "기준 + why" 로 명시(좁은 예시 암기 방지):
#   (A) 추천/목록형 캡처(특정 상품이 summary 에 식별 안 됨) → shop raw 검색 무용.
#       a. 진짜 특정 상품명이 있으면 그것만, b. "OO 추천/인기/순위" 류면 blog 로 큐레이션
#       글 검색, c. 단서가 빈약하면 needs_resource=false.
#   (B) local: 지역명+상호만 정확히, 길안내성 군더더기 제거.
#   (C) 판매단위/프로모션 토큰(2입 기획 등) 제거 — 검색 과도 협소화 방지.
#   (D) 일반명사화 브랜드 → 브랜드+제품군+식별자(인물/모델명) 함께 넣어 좁힘.
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
    "   - blog : 방법·개념·후기처럼 누군가 정리한 정보 글로 알고 싶은 것(국내). "
    "특정 상품이 식별되지 않는 '추천/인기/순위' 류 큐레이션도 여기로 보낸다.\n"
    "   - news : 시사·기사처럼 보도된 뉴스 원문을 다시 찾고 싶은 것.\n"
    "   - web  : 네이버 검색이 부적합한 것 — 해외 제품·영어 주제·국내 검색으로 잘 안 잡히는 "
    "일반 웹 정보. 이 경우 일반 웹검색(Tavily)으로 폴백한다.\n"
    "   - none : 위 어디에도 해당 안 되거나 needs_resource=false 인 경우.\n"
    "3) queries: category 가 none 이 아니면, 그 검색창에 그대로 넣어 좋은 결과가 나올 검색어 리스트.\n"
    "   핵심 규칙 — 검색은 '특정 대상'이 있을 때만 잘 된다. 대상이 흐릿하면 raw 로 넣지 말고 아래대로:\n"
    "   (A) 추천/목록형 캡처(요약에 살 '특정 상품'이 식별되지 않고 '육아템 추천','보온병 추천',"
    "'살림 꿀템','남성 약산성 세안제 추천'처럼 카테고리만 있는 경우): 그대로 shop 검색하면 무관한 "
    "일반 상품만 나오니 금지. 대신 —\n"
    "       a. 요약/메모에 진짜 특정 상품명·모델명이 박혀 있으면 그 상품명 1개만 shop 으로.\n"
    "       b. 특정 상품이 없고 'OO 추천/인기/순위' 류면 category=blog 로 큐레이션 글을 찾아라"
    "(검색어 예: 'OO 추천 순위', 'OO 인기 비교'). 누가 정리해 둔 목록 글이 사용자에게 더 유용하다.\n"
    "       c. 단서가 정말 빈약해(인물·브랜드·모델 어떤 고정점도 없음) 무엇을 찾을지조차 못 정하면 "
    "needs_resource=false.\n"
    "   (B) local(장소): 지역명 + 상호만 정확히 넣어라. '동탄 모프 미용실'처럼 상호가 분명하면 그대로 "
    "쓰되 '가는 길','위치','경로' 같은 길안내성 군더더기는 빼라(상호 자체로 지도가 잡힌다).\n"
    "   (C) 판매단위·프로모션 토큰 제거: '...100ml 2입 기획'의 '2입 기획','1+1','한정' 같은 판매단위/"
    "프로모션 토큰은 검색을 과도하게 좁히니 빼고 핵심 상품명만 남겨라.\n"
    "   (D) 일반명사처럼 검색되는 브랜드(LUCIER 안경처럼 브랜드명만으로는 무관한 일반 상품이 잡힘): "
    "브랜드 + 제품군 + 식별자(착용 인물·모델명·콜라보명)를 함께 넣어 좁혀라"
    "(예: 'LUCIER 박정민 안경 모델명').\n"
    "   - 대상이 처음부터 명확하면(예: '아이폰 16 프로 256 자급제') 정확한 상품명/검색어 1개만.\n"
    "   - web 카테고리면 영어/원어 검색어가 더 좋다.\n"
    "   - 마케팅 문구·군더더기는 빼고 핵심 토큰만. none 이면 빈 리스트 [].\n"
    "4) rationale: 왜 그렇게 라우팅했는지(특히 분해/폴백/blog 전환을 택한 이유) 한 줄.\n"
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


def latest_exp6_path() -> Path:
    """results/ 의 최신 exp6_*.json 경로. 없으면 에러."""
    matches = sorted(glob.glob(str(RESULTS_DIR / "exp6_*.json")))
    if not matches:
        raise FileNotFoundError(f"exp6 결과를 찾을 수 없음: {RESULTS_DIR}/exp6_*.json")
    return Path(matches[-1])


def is_target(r: dict) -> bool:
    """exp6 케이스 중 재실험 대상인지 — 검색을 돌렸으나 실패/빗나간 것만.

    none(검색불필요)·error 는 개선 대상이 아니므로 제외. judge.useful=false 또는
    usefulness<=3 이면 타겟.
    """
    if r.get("none") or "error" in r:
        return False
    judge = r.get("judge")
    if not isinstance(judge, dict):
        return False
    return judge.get("useful") is False or judge.get("usefulness", 5) <= 3


def load_prod_rows() -> dict[str, dict]:
    """프로덕션 JSONL → {full_id: row}. id prefix 매칭에 쓴다."""
    rows: dict[str, dict] = {}
    with DATA_PATH.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def select_targets() -> list[dict]:
    """exp6 결과에서 타겟 케이스 추출 → [{case(원본 row), before(exp6 결과 일부)}].

    exp6 의 id 는 [:8] prefix, prod jsonl 은 full UUID 이므로 prefix 로 매칭한다.
    """
    exp6 = json.loads(latest_exp6_path().read_text(encoding="utf-8"))
    prod = load_prod_rows()
    targets: list[dict] = []
    for r in exp6["results"]:
        if not is_target(r):
            continue
        prefix = r["id"]
        matches = [full for full in prod if full.startswith(prefix)]
        if len(matches) != 1:
            # 모호하거나 못 찾으면 건너뛰되 보고(데이터 정합성 문제)
            print(f"[warn] id prefix {prefix} → {len(matches)}건 매칭, 스킵")
            continue
        case = prod[matches[0]]
        before = {
            "useful": r["judge"]["useful"],
            "usefulness": r["judge"]["usefulness"],
            "queries": r["route"]["queries"],
            "route_category": r["route"]["category"],
            "comment": r["judge"]["comment"],
        }
        targets.append({"case": case, "before": before})
    return targets


def build_route_input(row: dict) -> str:
    """route 에 넘기는 입력 텍스트 — summary 중심 + 분류/메모/원본URL(있을 때만). exp6 동일."""
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


def _usage_entry(model: str, resp: object) -> dict:
    """generate_content 응답 → {model, tokens_in, tokens_out, cost_usd}.

    서버 구현(extract_token_usage / estimate_cost_usd)을 그대로 재사용한다.
    cost 는 Decimal → float 직렬화. 단가표에 없는 모델은 None(0 으로 오도 금지).
    """
    tin, tout = extract_token_usage(resp)
    cost = estimate_cost_usd(model, tin, tout)
    return {
        "model": model,
        "tokens_in": tin,
        "tokens_out": tout,
        "cost_usd": float(cost) if cost is not None else None,
    }


def route(c: genai.Client, route_input: str) -> tuple[dict, dict]:
    """라우터 모델로 기록(요약 중심)을 category + queries 로 라우팅. (routing, usage) 반환."""
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
    usage = _usage_entry(ROUTER_MODEL, resp)
    return Routing.model_validate_json(resp.text).model_dump(), usage


def _normalize_item(category: str, it: dict) -> dict:
    """네이버 엔드포인트별로 다른 응답 필드를 정제(분기). exp6 재사용."""
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
    """네이버 검색 API(카테고리별 엔드포인트) 호출 → {total, items} 또는 {error}. exp6 재사용."""
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
    """Tavily 웹검색 → {items:[{title,link,description}]} 또는 {error}. exp6 재사용."""
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
    """category 에 맞게 단일 query 검색. web 인데 키 없으면 skip 플래그. exp6 재사용."""
    if category == "web":
        if not tavily_key:
            return {"query": query, "_skipped": "no TAVILY_API_KEY"}
        res = search_tavily(http, tavily_key, query)
    else:
        res = search_naver(http, category, query)
    return {"query": query, **res}


def critique(c: genai.Client, route_input: str, collected: list[dict]) -> tuple[dict, dict]:
    """수집 결과가 충분한지 평가 → (critique, usage). exp6 재사용 + usage 계측."""
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
    usage = _usage_entry(ROUTER_MODEL, resp)
    return Critique.model_validate_json(resp.text).model_dump(), usage


def final_judge(
    c: genai.Client, route_input: str, routing: dict, collected: list[dict]
) -> tuple[dict, dict]:
    """기록 + 최종 수집 결과 → (judge, usage). exp6 재사용 + usage 계측."""
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
    usage = _usage_entry(JUDGE_MODEL, resp)
    out = FinalJudge.model_validate_json(resp.text).model_dump()
    if not out["useful"]:
        out["picked_urls"] = []  # 게이트: 무용 결과는 빈손
    out["picked_urls"] = out["picked_urls"][:3]
    return out, usage


def _collect_items(searches: list[dict]) -> list[dict]:
    """여러 query 검색 결과에서 items 만 평탄화(skip/error 제외). exp6 재사용."""
    items: list[dict] = []
    for s in searches:
        items.extend(s.get("items", []))
    return items


def _top3(searches: list[dict]) -> list[dict]:
    """엔드포인트별 top3 title+link 만 추려 per-case 보고에 담는다. exp6 재사용."""
    out: list[dict] = []
    for s in searches:
        for it in s.get("items", [])[:3]:
            out.append({"title": it.get("title", ""), "link": it.get("link", "")})
    return out


def _case_cost(usage_entries: list[dict]) -> float:
    """단계별 usage 의 cost_usd 합(None 은 0 취급 — 합산 목적상만)."""
    return float(sum((u["cost_usd"] or 0.0) for u in usage_entries))


def run_case(
    c: genai.Client,
    http: httpx.Client,
    target: dict,
    tavily_key: str | None,
) -> dict:
    """단일 타겟: route → search/critique loop(≤MAX_ITERS) → final judge. usage 누적."""
    case = target["case"]
    cid = case["id"][:8]
    route_input = build_route_input(case)
    row: dict = {
        "id": cid,
        "orig_summary": case.get("summary", ""),
        "orig_category": case.get("category"),
        "orig_url": case.get("url"),
        "before": target["before"],
    }
    usage: dict = {"route": None, "critique": None, "judge": None}

    routing, route_usage = route(c, route_input)
    usage["route"] = route_usage
    row["route"] = routing
    category = routing["category"]

    # none 게이트 — 검색·judge 스킵. (개선으로 라우터가 needs_resource=false 를 택할 수도 있다.)
    if not routing["needs_resource"] or category == "none":
        row["none"] = True
        row["iters"] = []
        row["searched_results"] = []
        row["critique"] = None
        row["judge"] = {"useful": False, "usefulness": 1, "picked_urls": [],
                        "comment": "route: needs_resource=false/none"}
        row["ranked_urls"] = []  # none 게이트: useful=false → 빈 랭킹
        row["web_called"] = False
        row["web_skipped"] = False
        row["usage"] = usage
        row["case_cost_usd"] = _case_cost([route_usage])
        return row

    # search/critique loop
    iters: list[dict] = []
    queries = list(routing["queries"]) or [route_input[:60]]  # 빈 queries 방어
    collected: list[dict] = []
    last_critique: dict | None = None
    web_skipped = False
    web_called = False

    for _it_idx in range(MAX_ITERS):
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
        crit, crit_usage = critique(c, route_input, collected)
        usage["critique"] = crit_usage  # 마지막 critique usage 기록(loop 누적은 합산에서)
        last_critique = crit
        iters.append({"queries": queries, "searches": searches, "critique": crit,
                      "critique_usage": crit_usage})

        if crit["sufficient"] or not crit.get("new_query"):
            break
        queries = [crit["new_query"]]  # 다음 iter 는 critique 가 제시한 1개로

    row["iters"] = iters
    row["web_called"] = web_called
    row["web_skipped"] = web_skipped
    # 추적용: 마지막 iter 의 엔드포인트별 top3 + 최종 critique
    row["searched_results"] = _top3(iters[-1]["searches"]) if iters else []
    row["critique"] = last_critique
    judge, judge_usage = final_judge(c, route_input, routing, collected)
    usage["judge"] = judge_usage
    row["judge"] = judge

    # 액션티어 랭킹(결정적, LLM 호출 없음 → 비용 불변). judge 의 관련성 필터는 유지:
    #   useful=false 면 빈손. useful=true 면 judge 가 고른 candidate 를 tier 로 재정렬.
    #   candidate = judge picked_urls 에 해당하는 collected item(매칭 실패 시 collected 전체).
    row["ranked_urls"] = rank_results(judge, collected, category, case.get("url"))

    # critique 는 loop 가 여러 번 돌 수 있으니, case_cost 는 모든 iter 의 critique 를 합산.
    all_critique_usage = [it["critique_usage"] for it in iters]
    row["usage"] = usage
    row["case_cost_usd"] = _case_cost([route_usage, *all_critique_usage, judge_usage])
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

    targets = select_targets()
    if not targets:
        print("재실험 대상 타겟이 없음 — exp6 결과를 확인하라")
        sys.exit(1)

    c = client()
    naver_headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": csecret,
    }
    print(
        f"exp6 실패 타겟 {len(targets)}건 재실험 × "
        f"(route {ROUTER_MODEL} → search/critique loop≤{MAX_ITERS} → final judge {JUDGE_MODEL})"
    )

    results = []
    with httpx.Client(headers=naver_headers, timeout=20) as http:
        for idx, target in enumerate(targets):
            cid8 = target["case"]["id"][:8]
            try:
                row = run_case(c, http, target, tavily_key)
            except Exception as e:  # noqa: BLE001 — 케이스 단위 실패 기록 후 계속
                row = {
                    "id": cid8,
                    "orig_summary": target["case"].get("summary", ""),
                    "orig_category": target["case"].get("category"),
                    "before": target["before"],
                    "error": str(e)[:200],
                }
                results.append(row)
                print(f"  [{idx+1}/{len(targets)}] [ERR] {cid8} {row['error'][:50]}")
                continue

            results.append(row)
            orig_cat = row.get("orig_category") or "-"
            bf = row["before"]
            fj = row["judge"]
            cost = row.get("case_cost_usd", 0.0)
            print(
                f"  [{idx+1}/{len(targets)}] [{str(orig_cat)[:8]:>8}] "
                f"before(u={bf['usefulness']},{'useful' if bf['useful'] else 'X'}) → "
                f"after(u={fj['usefulness']},{'useful' if fj['useful'] else 'X'}) "
                f"| ${cost:.6f}"
            )

    # 요약 — exp6 지표(타겟 부분집합 기준) + 개선 비교 + 비용
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

    # 개선 비교 — before(exp6) vs after(exp7), useful 플래그 기준
    improved = [r for r in ok if not r["before"]["useful"] and r["judge"]["useful"]]
    regressed = [r for r in ok if r["before"]["useful"] and not r["judge"]["useful"]]
    still_failing = [
        r for r in ok if not r["before"]["useful"] and not r["judge"]["useful"]
    ]
    before_useful = [r for r in ok if r["before"]["useful"]]
    exp6_useful_rate = round(len(before_useful) / max(len(ok), 1), 2)
    after_useful_rate = round(len(useful) / max(len(ok), 1), 2)

    # 원본 category 별 useful 분포(타겟 부분집합)
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

    # 비용 집계 — 단계별·모델별. None(단가 미상)은 합산에서 0 취급하되 미상 카운트 별도.
    cost_by_step: dict[str, float] = defaultdict(float)
    cost_by_model: dict[str, float] = defaultdict(float)
    unknown_model_calls: Counter = Counter()
    total_cost = 0.0
    for r in ok:
        usage = r.get("usage") or {}
        # route / judge 는 1회, critique 는 iter 마다 → iters 에서 합산
        step_entries: list[tuple[str, dict | None]] = [
            ("route", usage.get("route")),
            ("judge", usage.get("judge")),
        ]
        for it in r.get("iters", []):
            step_entries.append(("critique", it.get("critique_usage")))
        for step, entry in step_entries:
            if not entry:
                continue
            c_usd = entry.get("cost_usd")
            model = entry.get("model", "?")
            if c_usd is None:
                unknown_model_calls[model] += 1
                continue
            cost_by_step[step] += c_usd
            cost_by_model[model] += c_usd
            total_cost += c_usd

    tavily_calls = sum(1 for r in searched if r.get("web_called"))

    # 액션티어 랭킹 측정 — 보여준 1순위(ranked top1)의 tier 분포 + 원본일치(tier0) 발동 수.
    #   ranked_urls 가 빈(useful=false / none) 케이스는 분포에서 제외(보여줄 1순위가 없음).
    tier_distribution: Counter = Counter()
    original_match_count = 0
    for r in ok:
        ranked = r.get("ranked_urls") or []
        if ranked:
            tier_distribution[ranked[0]["tier_label"]] += 1
        if any(x.get("tier_num") == 0.0 for x in ranked):
            original_match_count += 1

    summary = {
        "router_model": ROUTER_MODEL,
        "judge_model": JUDGE_MODEL,
        "data": str(DATA_PATH.name),
        "source_exp6": latest_exp6_path().name,
        "cases": len(results),
        "errors": sum(1 for r in results if "error" in r),
        # exp6 지표(타겟 부분집합 기준)
        "final_useful_rate": after_useful_rate,
        "none_rate": round(len(none_cases) / max(len(ok), 1), 2),
        "refine_count": len(refined),
        "fallback_used": len(fallback_used),
        "fallback_skipped": len(fallback_skipped),
        "suppressed": len(suppressed),
        "avg_usefulness": round(sum(useful_scores) / max(len(useful_scores), 1), 2),
        "avg_iters": round(sum(iter_counts) / max(len(iter_counts), 1), 2),
        "by_category": by_category,
        # 개선 비교 (before=exp6, after=exp7)
        "improved": len(improved),
        "regressed": len(regressed),
        "still_failing": len(still_failing),
        "exp6_useful_rate": exp6_useful_rate,
        "useful_rate_delta": round(after_useful_rate - exp6_useful_rate, 2),
        # 비용 (Tavily 별도 — LLM 만 USD)
        "total_cost_usd": round(total_cost, 6),
        "avg_cost_per_case_usd": round(total_cost / max(len(ok), 1), 6),
        "cost_by_step": {k: round(v, 6) for k, v in cost_by_step.items()},
        "cost_by_model": {k: round(v, 6) for k, v in cost_by_model.items()},
        "unknown_pricing_calls": dict(unknown_model_calls),
        "tavily_calls": tavily_calls,
        # 액션티어 랭킹 (결정적 정렬 — LLM 비용에 영향 없음)
        "tier_distribution": dict(tier_distribution),
        "original_match_count": original_match_count,
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp7_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
