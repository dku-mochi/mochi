"""exp8 — Naver Search API vs Tavily backbone comparison.

Goal:
  Decide when ResourceFinder should prefer Naver Search API vs Tavily by running the
  same labelled queries through both backbones. This is deliberately deterministic:
  each case has expected/preferred domain patterns and the script computes hit@3/10,
  then writes raw top results for manual inspection.

Run:
  uv run --project mochi-backend python lab/active/shopping-product-link/exp8_search_backbone_compare.py
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

import httpx


LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"
NAVER_SEARCH_URL = "https://openapi.naver.com/v1/search/{category}.json"
TAVILY_SEARCH_URL = "https://api.tavily.com/search"
DISPLAY = 10
TAG_RE = re.compile(r"<[^>]+>")


@dataclass(frozen=True)
class Case:
    id: str
    vertical: str
    query: str
    naver_categories: tuple[str, ...]
    preferred: tuple[str, ...]
    acceptable: tuple[str, ...]
    note: str


CASES: list[Case] = [
    # Cosmetics: user trust is Olive Young / official / official smartstore before generic malls.
    Case("cos_01", "cosmetics", "롬앤 글래스팅 멜팅 밤", ("shop", "webkr"), ("oliveyoung", "romand", "smartstore.naver.com"), ("coupang", "search.shopping.naver.com", "naver.com"), "올영/공홈/공식스토어 우선"),
    Case("cos_02", "cosmetics", "아비브 어성초 패드 140매", ("shop", "webkr"), ("oliveyoung", "abib", "smartstore.naver.com"), ("coupang", "search.shopping.naver.com", "naver.com"), "올영 강한 제품"),
    Case("cos_03", "cosmetics", "토리든 다이브인 세럼", ("shop", "webkr"), ("oliveyoung", "torriden", "smartstore.naver.com"), ("coupang", "search.shopping.naver.com", "naver.com"), "공홈/올영 모두 가능"),
    Case("cos_04", "cosmetics", "라운드랩 독도 토너", ("shop", "webkr"), ("oliveyoung", "roundlab", "smartstore.naver.com"), ("coupang", "search.shopping.naver.com", "naver.com"), "화장품 범용"),
    # Fashion/app-based commerce: Naver Shopping often returns price comparison/open market;
    # Tavily may recover Musinsa/29CM/WConcept pages better.
    Case("fas_01", "fashion", "쿠어 스탠드 칼라 넥 다운 푸퍼", ("shop", "webkr"), ("musinsa", "coor", "29cm"), ("smartstore.naver.com", "coupang", "search.shopping.naver.com"), "브랜드/무신사 우선"),
    Case("fas_02", "fashion", "마뗑킴 카드지갑", ("shop", "webkr"), ("matinkim", "musinsa", "29cm", "wconcept"), ("smartstore.naver.com", "search.shopping.naver.com", "coupang"), "앱 기반 패션몰"),
    Case("fas_03", "fashion", "드파운드 가방", ("shop", "webkr"), ("depound", "29cm", "wconcept"), ("smartstore.naver.com", "search.shopping.naver.com", "coupang"), "공홈/편집샵 우선"),
    Case("fas_04", "fashion", "시에 SIE 원피스", ("shop", "webkr"), ("sie", "29cm", "wconcept"), ("smartstore.naver.com", "search.shopping.naver.com"), "브랜드명 짧음"),
    Case("fas_05", "fashion", "이미스 emis 볼캡", ("shop", "webkr"), ("emis", "29cm", "musinsa", "wconcept"), ("smartstore.naver.com", "search.shopping.naver.com", "coupang"), "앱/공홈 우선"),
    # Coupang screenshots: exact Coupang page may be hard; a reliable Coupang search URL may be better than API results.
    Case("cou_01", "coupang", "탐사수 2L 12개 쿠팡", ("shop", "webkr"), ("coupang.com",), ("naver.com", "search.shopping.naver.com"), "쿠팡 화면/생필품"),
    Case("cou_02", "coupang", "로지텍 MX Master 3S 펄화이트 쿠팡", ("shop", "webkr"), ("coupang.com", "logitech"), ("smartstore.naver.com", "search.shopping.naver.com", "naver.com"), "쿠팡 캡처지만 공식도 유효"),
    Case("cou_03", "coupang", "락앤락 메트로 머그 475 쿠팡", ("shop", "webkr"), ("coupang.com", "locknlock"), ("smartstore.naver.com", "search.shopping.naver.com"), "쿠팡 상품 링크 선호"),
    # Local: user expectation is Naver Map/Place, and for reservations Catchtable after map.
    Case("loc_01", "local", "런던베이글뮤지엄 안국", ("local", "webkr"), ("map.naver.com", "place.naver.com"), ("catchtable", "naver.com"), "네이버 지도 우선"),
    Case("loc_02", "local", "몽탄 예약", ("local", "webkr"), ("map.naver.com", "place.naver.com", "catchtable"), ("naver.com",), "지도+캐치테이블 둘 다 좋음"),
    Case("loc_03", "local", "금돼지식당 예약", ("local", "webkr"), ("map.naver.com", "place.naver.com", "catchtable"), ("naver.com",), "예약형 맛집"),
    Case("loc_04", "local", "스시소라 광화문 예약", ("local", "webkr"), ("map.naver.com", "place.naver.com", "catchtable"), ("naver.com",), "캐치테이블 가능성"),
    Case("loc_05", "local", "모프 동탄 미용실", ("local", "webkr"), ("map.naver.com", "place.naver.com"), ("instagram.com", "naver.com"), "소상공인 local 약점"),
    Case("loc_06", "local", "을지로 보석 예약", ("local", "webkr"), ("map.naver.com", "place.naver.com", "catchtable"), ("naver.com",), "예약/지도"),
    # Event/app-ish references.
    Case("evt_01", "event", "남산 페스티벌 예약", ("webkr", "blog", "news"), ("reservation", "booking", "naver.com", "seoul"), ("blog.naver.com", "instagram.com"), "행사 예약/신청"),
    Case("evt_02", "event", "서울시 청년문화패스 신청", ("webkr", "news", "blog"), ("youthcultureseoul", "seoul.go.kr"), ("blog.naver.com", "news.naver.com"), "공식 신청 페이지"),
    # Tech/general web: Tavily should generally win.
    Case("web_01", "web", "React Server Components official docs", ("webkr", "blog"), ("react.dev",), ("nextjs.org", "vercel.com"), "영문 공식문서"),
    Case("web_02", "web", "best mechanical keyboard for programming", ("webkr", "blog"), ("reddit.com", "rtings.com", "wirecutter", "tomsguide"), ("youtube.com", "medium.com"), "영문 일반 웹"),
]


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text or "").strip()


def hostish(url: str) -> str:
    try:
        parsed = urlparse(url)
    except ValueError:
        return ""
    host = (parsed.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host + (parsed.path or "").lower()


def match_any(url: str, patterns: tuple[str, ...]) -> bool:
    h = hostish(url)
    return any(p.lower() in h for p in patterns)


def normalize_naver_item(category: str, item: dict[str, Any]) -> dict[str, Any]:
    title = strip_tags(item.get("title", ""))
    link = item.get("link") or item.get("originallink") or ""
    row: dict[str, Any] = {"title": title, "url": link, "source": f"naver:{category}"}
    if category == "shop":
        row.update({
            "mallName": item.get("mallName", ""),
            "brand": item.get("brand", ""),
            "lprice": item.get("lprice", ""),
        })
    elif category == "local":
        row.update({
            "category": item.get("category", ""),
            "address": item.get("roadAddress") or item.get("address", ""),
            "mapx": item.get("mapx", ""),
            "mapy": item.get("mapy", ""),
        })
    else:
        row.update({"description": strip_tags(item.get("description", ""))})
    return row


def search_naver(http: httpx.Client, category: str, query: str) -> list[dict[str, Any]]:
    url = (
        NAVER_SEARCH_URL.format(category=category)
        + f"?query={quote(query)}&display={DISPLAY}&sort=sim"
    )
    resp = http.get(url)
    resp.raise_for_status()
    data = resp.json()
    return [normalize_naver_item(category, item) for item in data.get("items", [])]


def search_tavily(http: httpx.Client, api_key: str, query: str) -> list[dict[str, Any]]:
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
    return [
        {
            "title": item.get("title", ""),
            "url": item.get("url", ""),
            "source": "tavily",
            "description": (item.get("content", "") or "")[:240],
        }
        for item in data.get("results", [])
    ]


def score(items: list[dict[str, Any]], case: Case) -> dict[str, Any]:
    preferred_positions = [
        i + 1 for i, item in enumerate(items) if match_any(item.get("url", ""), case.preferred)
    ]
    acceptable_positions = [
        i + 1
        for i, item in enumerate(items)
        if match_any(item.get("url", ""), case.preferred + case.acceptable)
    ]
    return {
        "preferred_at": preferred_positions[0] if preferred_positions else None,
        "acceptable_at": acceptable_positions[0] if acceptable_positions else None,
        "preferred_hit3": bool(preferred_positions and preferred_positions[0] <= 3),
        "preferred_hit10": bool(preferred_positions and preferred_positions[0] <= 10),
        "acceptable_hit3": bool(acceptable_positions and acceptable_positions[0] <= 3),
        "acceptable_hit10": bool(acceptable_positions and acceptable_positions[0] <= 10),
    }


def dedupe(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for item in items:
        url = item.get("url", "")
        key = hostish(url) or url
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    by_vertical: dict[str, dict[str, Any]] = {}
    for vertical in sorted({r["vertical"] for r in rows}):
        subset = [r for r in rows if r["vertical"] == vertical]
        by_vertical[vertical] = summarize_subset(subset)
    return {"overall": summarize_subset(rows), "by_vertical": by_vertical}


def summarize_subset(rows: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(rows)
    if total == 0:
        return {}
    keys = [
        "preferred_hit3",
        "preferred_hit10",
        "acceptable_hit3",
        "acceptable_hit10",
    ]
    return {
        "cases": total,
        "naver": {k: sum(1 for r in rows if r["naver_score"][k]) / total for k in keys},
        "tavily": {k: sum(1 for r in rows if r["tavily_score"][k]) / total for k in keys},
    }


def main() -> None:
    load_env(Path("mochi-backend/.env"))
    cid = os.environ.get("NAVER_CLIENT_ID")
    secret = os.environ.get("NAVER_CLIENT_SECRET")
    tavily_key = os.environ.get("TAVILY_API_KEY")
    if not cid or not secret or not tavily_key:
        raise SystemExit("NAVER_CLIENT_ID/NAVER_CLIENT_SECRET/TAVILY_API_KEY required")

    headers = {
        "X-Naver-Client-Id": cid,
        "X-Naver-Client-Secret": secret,
    }
    rows: list[dict[str, Any]] = []
    with httpx.Client(headers=headers, timeout=20) as http:
        for case in CASES:
            print(f"[case] {case.id} {case.query}")
            naver_items: list[dict[str, Any]] = []
            naver_errors: list[str] = []
            for category in case.naver_categories:
                try:
                    naver_items.extend(search_naver(http, category, case.query))
                except (httpx.HTTPError, ValueError) as exc:
                    naver_errors.append(f"{category}: {exc}")
                time.sleep(0.15)
            try:
                tavily_items = search_tavily(http, tavily_key, case.query)
                tavily_error = None
            except (httpx.HTTPError, ValueError) as exc:
                tavily_items = []
                tavily_error = str(exc)

            naver_items = dedupe(naver_items)
            tavily_items = dedupe(tavily_items)
            rows.append({
                "id": case.id,
                "vertical": case.vertical,
                "query": case.query,
                "note": case.note,
                "preferred": case.preferred,
                "acceptable": case.acceptable,
                "naver_categories": case.naver_categories,
                "naver_score": score(naver_items, case),
                "tavily_score": score(tavily_items, case),
                "naver_top": naver_items[:DISPLAY],
                "tavily_top": tavily_items[:DISPLAY],
                "naver_errors": naver_errors,
                "tavily_error": tavily_error,
            })
            time.sleep(0.2)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = {
        "created_at": stamp,
        "display": DISPLAY,
        "summary": summarize(rows),
        "rows": rows,
    }
    path = RESULTS_DIR / f"exp8_backbone_compare_{stamp}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out["summary"], ensure_ascii=False, indent=2))
    print(f"[ok] wrote {path}")


if __name__ == "__main__":
    main()
