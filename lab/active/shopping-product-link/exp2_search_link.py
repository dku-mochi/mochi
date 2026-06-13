"""쇼핑 검색 상태 링크 실험 (exp2) — 상품명을 "검색된 상태" URL 로 제공하는 것이 실제로 가능한가.

배경:
  특정 판매자를 우리가 고를 수 없으므로(같은 상품을 여러 판매자가 판다), 상품 상세
  대신 *커머스 검색 결과 상태*의 링크를 카드 상세에 단다는 아이디어. 검증할 것:
  1) 한국어 상품명이 URL 로 안전하게 인코딩되는가
  2) 각 커머스의 검색 URL 패턴이 유효한가 (redirect/차단/파라미터 변경 여부)
  3) 봇 차단 여부 — 서버에서 링크 미리 검증(dead-link 체크)이 가능한지 판단 근거.
     주의: 봇 차단(403 등) ≠ 사용자 브라우저에서 실패. 최종 UX 검증은 실기기에서
     출력된 마크다운 링크 목록을 직접 탭해 확인한다.

방법:
  exp1 결과(최신 exp1_*.json)의 product_query 들 — 또는 --query 수동 입력 — 에 대해
  쿠팡/네이버쇼핑/네이버통합/구글 검색 URL 을 만들고, iPhone Safari UA 로 GET 하여
  status·최종 URL·본문 크기·상품 토큰 등장 비율(러프한 관련성 프록시)을 기록한다.

실행 (repo 루트에서):
  uv run --project mochi-backend python lab/active/shopping-product-link/exp2_search_link.py
  uv run --project mochi-backend python lab/active/shopping-product-link/exp2_search_link.py --query "로지텍 MX Master 3S"

결과: results/exp2_YYYYMMDD_HHMMSS.json + results/exp2_links_*.md (실기기 수동 확인용)
"""
import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import httpx

sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"

# 사용자가 링크를 여는 환경과 동일하게 — iPhone Safari.
UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"
)
HEADERS = {"User-Agent": UA, "Accept-Language": "ko-KR,ko;q=0.9"}

PROVIDERS = {
    "coupang": "https://www.coupang.com/np/search?q={q}",
    "naver_shopping": "https://search.shopping.naver.com/search/all?query={q}",
    "naver_total": "https://search.naver.com/search.naver?query={q}",
    "google": "https://www.google.com/search?q={q}",
}


def latest_exp1_queries() -> list[str]:
    files = sorted(RESULTS_DIR.glob("exp1_*.json"))
    if not files:
        return []
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    queries: list[str] = []
    for row in data["results"]:
        for model_result in row.values():
            if isinstance(model_result, dict) and model_result.get("product_query"):
                q = model_result["product_query"]
                if q not in queries:
                    queries.append(q)
    return queries


def check(client: httpx.Client, url: str, query: str) -> dict:
    try:
        resp = client.get(url)
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        return {"url": url, "error": str(e)[:150]}
    body = resp.text.lower()
    tokens = [t.lower() for t in query.split() if len(t) > 1]
    hits = sum(1 for t in tokens if t in body)
    return {
        "url": url,
        "status": resp.status_code,
        "final_url": str(resp.url),
        "body_bytes": len(resp.content),
        "token_hit_rate": round(hits / max(len(tokens), 1), 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", action="append", help="수동 상품명 (반복 가능)")
    args = parser.parse_args()

    queries = args.query or latest_exp1_queries()
    if not queries:
        print("쿼리 없음 — exp1 을 먼저 돌리거나 --query 를 줘라.")
        sys.exit(1)
    print(f"쿼리 {len(queries)}건 × 제공자 {len(PROVIDERS)}곳")

    results = []
    md_lines = ["# exp2 검색 링크 — 실기기 수동 확인 목록", ""]
    with httpx.Client(headers=HEADERS, follow_redirects=True, timeout=15) as client:
        for q in queries:
            row = {"query": q, "providers": {}}
            md_lines.append(f"## {q}")
            for name, pattern in PROVIDERS.items():
                url = pattern.format(q=quote(q))
                row["providers"][name] = check(client, url, q)
                r = row["providers"][name]
                status = r.get("status", r.get("error", "?"))
                print(f"  [{status}] {name:15s} {q[:30]}  hit={r.get('token_hit_rate', '-')}")
                md_lines.append(f"- [{name}]({url}) — status {status}")
            md_lines.append("")
            results.append(row)

    RESULTS_DIR.mkdir(exist_ok=True)
    stamp = f"{datetime.now():%Y%m%d_%H%M%S}"
    out = RESULTS_DIR / f"exp2_{stamp}.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    md = RESULTS_DIR / f"exp2_links_{stamp}.md"
    md.write_text("\n".join(md_lines), encoding="utf-8")
    print(f"\n결과 저장: {out}\n수동 확인 목록: {md}")


if __name__ == "__main__":
    main()
