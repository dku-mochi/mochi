"""장소 캡처에서 '네이버지도 + 캐치테이블/예약' 을 뽑아낼 수 있는지 백본별로 확인.

사용자 니즈: 맛집/장소면 ① 네이버지도 URL + ② 캐치테이블·예약사이트 URL 로 응답.
각 가게에 대해 네이버 local / 네이버 webkr / tavily 를 때려 catchtable·예약 도메인이
어느 백본에서 실제로 잡히는지 본다.

Run (cwd=mochi-backend):
  cd mochi-backend && uv run python ../lab/active/shopping-product-link/probe_places.py
"""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path
from urllib.parse import quote

import httpx

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "mochi-backend"))

from app.core.config import get_settings  # noqa: E402

PLACES = ["두툼", "차경", "파스타타타", "양은이네 신대방삼거리역직영점"]
RESERVE_HOSTS = ("catchtable", "tabling", "naver.com/booking", "booking.naver",
                 "agoda", "yanolja", "goodchoice")


def strip_tags(t: str) -> str:
    return re.sub(r"<[^>]+>", "", t).strip()


def mark(link: str) -> str:
    low = link.lower()
    return " ⭐예약도메인" if any(h in low for h in RESERVE_HOSTS) else ""


async def naver(http, category: str, query: str) -> list[dict]:
    url = (f"https://openapi.naver.com/v1/search/{category}.json"
           f"?query={quote(query)}&display=5&sort=sim")
    try:
        r = await http.get(url)
        r.raise_for_status()
        return r.json().get("items", [])
    except (httpx.HTTPError, ValueError) as e:
        return [{"_err": str(e)[:120]}]


async def tavily(http, key: str, query: str) -> list[dict]:
    try:
        r = await http.post("https://api.tavily.com/search",
                            json={"api_key": key, "query": query,
                                  "max_results": 5, "search_depth": "basic"})
        r.raise_for_status()
        return [{"title": x.get("title", ""), "link": x.get("url", "")}
                for x in r.json().get("results", [])]
    except (httpx.HTTPError, ValueError) as e:
        return [{"_err": str(e)[:120]}]


def show(tag: str, items: list[dict]) -> None:
    print(f"  ── {tag}")
    if not items:
        print("     (0건)")
    for it in items[:5]:
        if "_err" in it:
            print(f"     ⚠️ {it['_err']}")
            continue
        link = it.get("link", "")
        title = strip_tags(it.get("title", ""))
        print(f"     {title[:40]:<42} {link}{mark(link)}")


async def main() -> None:
    s = get_settings()
    headers = {"X-Naver-Client-Id": s.naver_client_id or "",
               "X-Naver-Client-Secret": s.naver_client_secret or ""}
    async with httpx.AsyncClient(headers=headers, timeout=20) as http:
        for place in PLACES:
            print("\n" + "=" * 76)
            print(f"### {place}")
            show("naver local", await naver(http, "local", place))
            show(f"naver webkr '{place} 캐치테이블 예약'",
                 await naver(http, "webkr", f"{place} 캐치테이블 예약"))
            if s.tavily_api_key:
                show(f"tavily '{place} 예약 캐치테이블'",
                     await tavily(http, s.tavily_api_key, f"{place} 예약 캐치테이블"))


if __name__ == "__main__":
    asyncio.run(main())
