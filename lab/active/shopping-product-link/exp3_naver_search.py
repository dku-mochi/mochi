"""네이버 쇼핑 검색 API 실재성 실험 (exp3) — 식별된 검색어로 실제 상품이 나오는가.

배경:
  exp1 은 캡처에서 product_query 를 뽑을 수 있음을, exp2 는 그 검색어로 만든
  커머스 "검색된 상태" URL 이 200 응답하고 본문에 검색어 토큰이 있음을 확인했다.
  하지만 exp2 는 *실제 상품 추출/실재 확인*은 하지 않았다(HTML 본문 토큰 매칭은
  러프한 프록시일 뿐). exp3 은 한 단계 더 들어가, 네이버 쇼핑 검색 API 로
  실제 상품을 검색해 "잘 찾는지"를 정량화한다.

  핵심 질문: shopping_product 검색어로 네이버 쇼핑 API 를 치면 실제로 그 상품이
  나오는가, 아니면 헛검색(total=0 또는 전혀 다른 상품)인가. 이게 카드 상세에
  구매 링크/상품 카드를 다는 기능의 실현 가능성 근거가 된다.

방법:
  - 입력: exp1 결과(results/exp1_*.json)에서 gemini-3.1-flash-lite 가
    is_shopping=true 로 본 + product_query 가 non-null 인 케이스의 검색어들
    (약 15건). 검색어는 동적으로 추출 — 하드코딩하지 않는다.
  - 검색: 각 검색어를 네이버 쇼핑 검색 API(/v1/search/shop.json)에 query 로
    던지고 total·상위 상품(title/mallName/lprice 등)을 받는다.
  - 평가: LLM judge(gemini-3.5-flash, temperature=0.0)가 [원본 product_query]
    + [상위 5개 상품 title]을 보고 match_score(1~5)·has_buyable 을 채점.

측정 항목 (per query):
  1. total — 상품 실재 여부. 0 이면 헛검색(게이트에서 제외해야 할 케이스).
  2. 상위 5개 상품의 title(HTML <b> 태그 strip)·mallName·lprice.
  3. relevance (LLM judge):
     - match_score 1~5: 검색 결과 안에 캡처가 가리킨 그 상품으로 볼 만한 게
       있는가. 5=정확히 그 상품 상위노출, 1=전혀 다른 것뿐.
     - has_buyable: bool — 구매로 이어줄 만한 결과가 있나.
  4. 부수 기록: 상위 상품 mallName 분포에 쿠팡이 포함되는지
     (쿠팡 상품이 네이버 가격비교에 잡히는지 — 쿠팡 직접 추출 대안 단서).

요약 (summary):
  - found_rate     = total>0 인 검색어 비율
  - avg_match_score = judge match_score 평균
  - buyable_rate   = has_buyable=true 비율

인증 / 키 (네이버 검색 API):
  네이버 개발자센터(https://developers.naver.com)에서 "검색" API 를 등록해
  Client ID/Secret 을 발급받아 환경변수로 준다:
    NAVER_CLIENT_ID, NAVER_CLIENT_SECRET
  Gemini judge 는 exp1 과 동일하게 Vertex AI(ADC + GOOGLE_CLOUD_PROJECT) 사용.

실행 (repo 루트에서, 키 발급 후):
  GOOGLE_CLOUD_PROJECT=<proj> \\
    NAVER_CLIENT_ID=<id> NAVER_CLIENT_SECRET=<secret> \\
    uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp3_naver_search.py

결과: results/exp3_YYYYMMDD_HHMMSS.json (summary + per-query 상세)
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

# exp1 의 어느 모델 추출 결과를 입력으로 쓸지 — 프로덕션 agent 동일 모델.
SOURCE_MODEL = "gemini-3.1-flash-lite"

JUDGE_MODEL = "gemini-3.5-flash"
LOCATION = "global"

NAVER_SHOP_URL = "https://openapi.naver.com/v1/search/shop.json"
DISPLAY = 10           # API 가 돌려줄 결과 수 (최대 100, 실험은 10)
TOP_N = 5              # judge 와 요약에 쓸 상위 N개
SORT = "sim"           # 정확도순
REQUEST_SLEEP = 0.3    # rate limit 배려 — query 간 짧은 sleep

TAG_RE = re.compile(r"<[^>]+>")  # 네이버 title 의 <b> 등 HTML 태그 strip


JUDGE_PROMPT = (
    "너는 평가자다. 모찌(개인 기억 비서)가 캡처에서 뽑은 상품 검색어와, 그 검색어로 "
    "네이버 쇼핑 API 를 친 상위 결과 상품명들을 비교해 채점하라.\n"
    "- match_score (1-5): 검색 결과 상품들 중에 '캡처가 가리킨 그 상품'으로 볼 만한 게 "
    "있는가. 5=정확히 그 상품이 상위에 노출, 3=같은 품목이지만 모델/브랜드가 섞여 애매, "
    "1=전혀 다른 상품들뿐.\n"
    "- has_buyable: 이 결과 중 사용자를 실제 구매로 이어줄 만한 상품이 하나라도 있는가."
)


class JudgeScore(BaseModel):
    match_score: int = Field(ge=1, le=5)
    has_buyable: bool
    comment: str


def client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def latest_exp1_queries() -> list[str]:
    """최신 exp1 결과에서 SOURCE_MODEL 의 is_shopping=true + product_query non-null 추출."""
    files = sorted(RESULTS_DIR.glob("exp1_*.json"))
    if not files:
        return []
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    queries: list[str] = []
    for row in data["results"]:
        m = row.get(SOURCE_MODEL)
        if isinstance(m, dict) and m.get("is_shopping") and m.get("product_query"):
            q = m["product_query"]
            if q not in queries:
                queries.append(q)
    return queries


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text).strip()


def search_naver(http: httpx.Client, query: str) -> dict:
    """네이버 쇼핑 검색 API 호출 → {total, items(상위 N개 정제)} 또는 {error}."""
    url = f"{NAVER_SHOP_URL}?query={quote(query)}&display={DISPLAY}&sort={SORT}"
    try:
        resp = http.get(url)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        return {"error": str(e)[:200]}

    items = []
    for it in data.get("items", [])[:TOP_N]:
        items.append(
            {
                "title": strip_tags(it.get("title", "")),
                "mallName": it.get("mallName", ""),
                "lprice": it.get("lprice", ""),
                "brand": it.get("brand", ""),
                "productType": it.get("productType", ""),
                "link": it.get("link", ""),
            }
        )
    return {"total": data.get("total", 0), "items": items}


def judge_relevance(c: genai.Client, query: str, items: list[dict]) -> dict:
    titles = [it["title"] for it in items]
    parts = [
        types.Part.from_text(
            text=(
                f"원본 상품 검색어: {query}\n"
                f"네이버 쇼핑 상위 {len(titles)}개 상품명:\n"
                + "\n".join(f"  {i+1}. {t}" for i, t in enumerate(titles))
            )
        )
    ]
    resp = c.models.generate_content(
        model=JUDGE_MODEL,
        contents=[types.Content(role="user", parts=parts)],
        config=types.GenerateContentConfig(
            system_instruction=JUDGE_PROMPT,
            response_mime_type="application/json",
            response_schema=JudgeScore,
            temperature=0.0,
        ),
    )
    return JudgeScore.model_validate_json(resp.text).model_dump()


def has_coupang(items: list[dict]) -> bool:
    return any("쿠팡" in it["mallName"] or "coupang" in it["mallName"].lower() for it in items)


def main() -> None:
    cid = os.environ.get("NAVER_CLIENT_ID")
    csecret = os.environ.get("NAVER_CLIENT_SECRET")
    if not cid or not csecret:
        print(
            "네이버 개발자센터에서 검색 API 키 발급 후 "
            "NAVER_CLIENT_ID/NAVER_CLIENT_SECRET 환경변수 설정 필요"
        )
        sys.exit(1)

    queries = latest_exp1_queries()
    if not queries:
        print(f"쿼리 없음 — exp1 을 먼저 돌려 {SOURCE_MODEL} 의 쇼핑 검색어를 만들어라.")
        sys.exit(1)

    c = client()
    naver_headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": csecret,
    }
    print(f"검색어 {len(queries)}건 ({SOURCE_MODEL} 산출) × 네이버 쇼핑 검색 API")

    results = []
    with httpx.Client(headers=naver_headers, timeout=15) as http:
        for q in queries:
            row: dict = {"query": q}
            search = search_naver(http, q)
            if "error" in search:
                row["error"] = search["error"]
                results.append(row)
                print(f"  [ERR] {q[:30]:32s} {search['error'][:60]}")
                time.sleep(REQUEST_SLEEP)
                continue

            row["total"] = search["total"]
            row["items"] = search["items"]
            row["has_coupang"] = has_coupang(search["items"])

            if search["total"] > 0 and search["items"]:
                try:
                    row["judge"] = judge_relevance(c, q, search["items"])
                except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
                    row["judge"] = {"error": str(e)[:200]}
            else:
                row["judge"] = None  # 헛검색 — judge 생략

            results.append(row)
            ms = (row.get("judge") or {}).get("match_score", "-") if row.get("judge") else "-"
            print(
                f"  [OK]  {q[:30]:32s} total={row['total']:>6}  "
                f"top={len(search['items'])}  match={ms}  coupang={row['has_coupang']}"
            )
            time.sleep(REQUEST_SLEEP)

    # 요약
    ok = [r for r in results if "error" not in r]
    found = [r for r in ok if r.get("total", 0) > 0]
    judged = [r["judge"] for r in ok if isinstance(r.get("judge"), dict) and "error" not in r["judge"]]
    summary = {
        "source_model": SOURCE_MODEL,
        "queries": len(results),
        "errors": sum(1 for r in results if "error" in r),
        "found_count": len(found),
        "found_rate": round(len(found) / max(len(results), 1), 2),
        "avg_match_score": round(sum(j["match_score"] for j in judged) / max(len(judged), 1), 2),
        "buyable_rate": round(
            sum(1 for j in judged if j["has_buyable"]) / max(len(judged), 1), 2
        ),
        "coupang_seen": sum(1 for r in ok if r.get("has_coupang")),
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp3_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
