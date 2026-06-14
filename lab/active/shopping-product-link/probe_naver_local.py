"""네이버 local 검색을 직접 때려 문제1·2를 재현한다 (judge 없이 raw 결과만).

문제1: 호텔이 "리치몬드호텔 야마가타 에키마에 예약" 검색 지도링크로 나옴
  → '예약' 액션동사가 지도 검색어에 섞이면 검색이 깨지는가?
  → 해외(일본) 장소가 네이버 local 에 잡히는가?
문제2: 네이버지도 스크린샷 "양은이네 신대방삼거리역직영점" 이 안 옴
  → 네이버 local 에 실제로 잡히는가? (잡히면 tool 은 정상 → 메인 미호출이 원인)

Run:
  uv run --project mochi-backend python lab/active/shopping-product-link/probe_naver_local.py
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from urllib.parse import quote

import httpx

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "mochi-backend"))

from app.core.config import get_settings  # noqa: E402

CASES: list[tuple[str, str]] = [
    # 문제1 — 예약 동사 유무 / 해외 장소
    ("local", "리치몬드호텔 야마가타 에키마에 예약"),
    ("local", "리치몬드호텔 야마가타 에키마에"),
    ("local", "리치몬드 호텔 야마가타"),
    ("local", "richmond hotel yamagata"),
    # 문제2 — 네이버지도 스크린샷 장소
    ("local", "양은이네 신대방삼거리역직영점"),
    ("local", "양은이네 신대방삼거리"),
    ("local", "양은이네"),
]


async def search_naver_local(http: httpx.AsyncClient, query: str) -> dict:
    url = (
        "https://openapi.naver.com/v1/search/local.json"
        f"?query={quote(query)}&display=5&sort=random"
    )
    try:
        resp = await http.get(url)
        resp.raise_for_status()
        return resp.json()
    except httpx.HTTPStatusError as exc:
        return {"_error": f"HTTP {exc.response.status_code}: {exc.response.text[:200]}"}
    except (httpx.HTTPError, ValueError) as exc:
        return {"_error": str(exc)}


def strip_tags(text: str) -> str:
    import re

    return re.sub(r"<[^>]+>", "", text).strip()


async def main() -> None:
    settings = get_settings()
    headers = {
        "X-Naver-Client-Id": settings.naver_client_id or "",
        "X-Naver-Client-Secret": settings.naver_client_secret or "",
    }
    async with httpx.AsyncClient(headers=headers, timeout=20) as http:
        for category, query in CASES:
            data = await search_naver_local(http, query)
            print("\n" + "=" * 72)
            print(f"[{category}] query={query!r}")
            if "_error" in data:
                print(f"  ⚠️  {data['_error']}")
                continue
            items = data.get("items", [])
            total = data.get("total", 0)
            print(f"  total={total}  returned={len(items)}")
            for i, it in enumerate(items, 1):
                title = strip_tags(it.get("title", ""))
                addr = it.get("roadAddress") or it.get("address", "")
                cat = it.get("category", "")
                link = it.get("link", "")
                print(f"  {i}. {title}  | {cat}")
                print(f"     {addr}")
                if link:
                    print(f"     {link}")


if __name__ == "__main__":
    asyncio.run(main())
