"""Run backend ResourceFinder against lab/data/mochi_items_prod.jsonl and render HTML.

This is a text-only harness: the production JSONL has summary/category/user_memo but
not original screenshots. A small router converts each row into ResourceFinderInput,
then the real backend ResourceFinderTool runs with the same search/ranking code used
by the app.

Run:
  uv run --project mochi-backend python lab/active/shopping-product-link/resource_finder_prod_report.py
"""

from __future__ import annotations

import argparse
import asyncio
import html
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Literal, cast

from google import genai
from google.genai import types
from pydantic import BaseModel, Field


REPO_ROOT = Path(__file__).resolve().parents[3]
LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"
DATA_PATH = REPO_ROOT / "lab/data/mochi_items_prod.jsonl"
ROUTER_MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"


class Route(BaseModel):
    needs_resource: bool
    queries: list[str] = Field(default_factory=list)
    category: Literal["shop", "local", "blog", "news", "web"] = "web"
    rank_profile: Literal[
        "auto", "general", "cosmetics", "fashion", "electronics", "local",
        "event_booking", "coupang", "web",
    ] = "auto"
    source_app: Literal[
        "unknown", "coupang", "naver_map", "naver_shopping", "oliveyoung",
        "musinsa", "instagram", "youtube", "safari", "browser",
    ] = "unknown"
    reason: str


ROUTER_PROMPT = (
    "너는 모찌의 참고 링크 라우터다. 저장된 기록의 summary/category/user_memo 를 보고, "
    "사용자가 나중에 다시 눌러볼 만한 외부 링크가 필요한지 판단하라. 이미지 원본은 없으니 "
    "텍스트에 보이는 대상만 사용하고 추측하지 마라.\n"
    "- needs_resource=false: 친구대화, 단순 일정/할 일, 개인 메모, 대상이 너무 모호한 기록.\n"
    "- category: shop/local/blog/news/web.\n"
    "- queries: 검색창에 넣을 구체 검색어. 사용자 메모가 제품명/장소명이면 우선 사용.\n"
    "- rank_profile: cosmetics/fashion/electronics/local/event_booking/coupang/web/general/auto.\n"
    "- source_app: 쿠팡/네이버지도 등 출처가 텍스트에 명확할 때만 지정.\n"
    "신뢰도 기준: local 예약은 네이버 지도 > 캐치테이블, 화장품은 올리브영 > 공홈 > 공식 스마트스토어, "
    "패션은 공홈/무신사/29CM/W컨셉 우선, 쿠팡 캡처는 쿠팡 검색 fallback 이 유용하다."
)


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def vertex_client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def read_rows(path: Path, limit: int | None) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            rows.append(json.loads(line))
            if limit is not None and len(rows) >= limit:
                break
    return rows


def route_row(client: genai.Client, row: dict[str, object]) -> Route:
    text = json.dumps(
        {
            "summary": row.get("summary"),
            "category": row.get("category"),
            "user_memo": row.get("user_memo"),
            "channel": row.get("channel"),
            "url": row.get("url"),
        },
        ensure_ascii=False,
    )
    resp = client.models.generate_content(
        model=ROUTER_MODEL,
        contents=[types.Content(role="user", parts=[types.Part.from_text(text=text)])],
        config=types.GenerateContentConfig(
            system_instruction=ROUTER_PROMPT,
            response_mime_type="application/json",
            response_schema=Route,
            temperature=0.0,
        ),
    )
    route = Route.model_validate_json(resp.text)
    if not route.needs_resource:
        route.queries = []
    return route


def row_text(row: dict[str, object]) -> str:
    parts = []
    if row.get("user_memo"):
        parts.append(f"메모: {row['user_memo']}")
    if row.get("summary"):
        parts.append(str(row["summary"]))
    return "\n".join(parts)


async def run_case(tool: object, row: dict[str, object], route: Route) -> dict[str, object]:
    from app.modules.agent.infrastructure.tools.resource_finder import ResourceFinderInput

    if not route.needs_resource or not route.queries:
        return {"route": route.model_dump(), "output": None}
    payload = ResourceFinderInput(
        queries=route.queries,
        category=route.category,
        original_url=cast(str | None, row.get("url")),
        rank_profile=route.rank_profile,
        source_app=route.source_app,
    )
    out, usage = await tool.run(payload)  # type: ignore[attr-defined]
    return {
        "route": route.model_dump(),
        "output": out.model_dump(),
        "usage": {
            "tokens_in": usage.tokens_in,
            "tokens_out": usage.tokens_out,
            "latency_ms": usage.latency_ms,
        },
    }


def render_html(results: list[dict[str, object]], stamp: str) -> str:
    useful = sum(1 for r in results if ((r.get("output") or {}) or {}).get("useful"))
    attempted = sum(1 for r in results if r.get("output"))
    rows = []
    for idx, result in enumerate(results, 1):
        row = cast(dict[str, object], result["row"])
        route = cast(dict[str, object], result["route"])
        output = cast(dict[str, object] | None, result.get("output"))
        links = cast(list[dict[str, object]], (output or {}).get("ranked_urls") or [])
        chips = [
            str(route.get("category")),
            str(route.get("rank_profile")),
            str(route.get("source_app")),
        ]
        link_html = ""
        if links:
            link_html = "".join(
                f"""<a class="link provider-{html.escape(str(link.get('provider')))}" href="{html.escape(str(link.get('url')))}" target="_blank">
  <span class="label">{html.escape(str(link.get('label')))}</span>
  <span class="title">{html.escape(str(link.get('title')))}</span>
  <span class="meta">{html.escape(str(link.get('provider')))} · {html.escape(str(link.get('source')))}</span>
</a>"""
                for link in links
            )
        elif output:
            link_html = f"<div class='empty'>게이트 차단: {html.escape(str(output.get('comment') or 'not useful'))}</div>"
        else:
            link_html = f"<div class='empty'>링크 불필요: {html.escape(str(route.get('reason') or ''))}</div>"
        rows.append(
            f"""<article class="card">
  <div class="head">
    <span class="num">#{idx}</span>
    <span class="cat">{html.escape(str(row.get('category') or ''))}</span>
    {''.join(f'<span class="chip">{html.escape(chip)}</span>' for chip in chips)}
  </div>
  <p class="summary">{html.escape(row_text(row))}</p>
  <p class="reason">{html.escape(str(route.get('reason') or ''))}</p>
  <div class="links">{link_html}</div>
</article>"""
        )
    return f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>ResourceFinder prod JSONL report {stamp}</title>
<style>
body {{ margin:0; font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#f7f7f4; color:#1f2328; }}
header {{ position:sticky; top:0; background:#fff; border-bottom:1px solid #ddd; padding:16px 24px; z-index:1; }}
h1 {{ margin:0 0 4px; font-size:20px; }}
.stats {{ color:#59636e; }}
main {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(360px,1fr)); gap:14px; padding:18px; }}
.card {{ background:#fff; border:1px solid #ddd; border-radius:8px; padding:14px; box-shadow:0 1px 2px rgba(0,0,0,.04); }}
.head {{ display:flex; align-items:center; gap:6px; flex-wrap:wrap; margin-bottom:10px; }}
.num {{ font-weight:700; color:#0969da; }}
.cat {{ font-weight:600; margin-right:auto; }}
.chip {{ border:1px solid #d0d7de; border-radius:999px; padding:2px 7px; color:#59636e; font-size:12px; }}
.summary {{ white-space:pre-wrap; margin:0 0 10px; }}
.reason {{ color:#6e7781; margin:0 0 12px; font-size:13px; }}
.links {{ display:grid; gap:8px; }}
.link {{ display:grid; gap:2px; text-decoration:none; border:1px solid #d8dee4; border-radius:7px; padding:10px; color:#1f2328; }}
.link:hover {{ border-color:#0969da; background:#f6f8fa; }}
.label {{ font-weight:700; }}
.title {{ color:#39424e; }}
.meta {{ color:#6e7781; font-size:12px; }}
.empty {{ color:#8c4a00; background:#fff8c5; border:1px solid #f0d98c; border-radius:7px; padding:10px; }}
</style>
</head>
<body>
<header>
  <h1>ResourceFinder prod JSONL report</h1>
  <div class="stats">{len(results)} rows · attempted {attempted} · useful {useful} · {stamp}</div>
</header>
<main>
{''.join(rows)}
</main>
</body>
</html>"""


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DATA_PATH)
    parser.add_argument("--limit", type=int, default=None)
    args = parser.parse_args()

    load_env(REPO_ROOT / "mochi-backend/.env")
    sys.path.insert(0, str(REPO_ROOT / "mochi-backend"))

    from app.modules.agent.infrastructure.tools.resource_finder import ResourceFinderTool

    rows = read_rows(args.input, args.limit)
    router = vertex_client()
    tool = ResourceFinderTool()
    results: list[dict[str, object]] = []
    for idx, row in enumerate(rows, 1):
        print(f"[{idx}/{len(rows)}] {row.get('id')}")
        try:
            route = route_row(router, row)
            result = await run_case(tool, row, route)
        except Exception as exc:  # lab report should continue and show failures.
            result = {
                "route": {
                    "needs_resource": False,
                    "queries": [],
                    "category": "web",
                    "rank_profile": "auto",
                    "source_app": "unknown",
                    "reason": f"error: {exc}",
                },
                "output": None,
                "error": str(exc),
            }
        result["row"] = row
        results.append(result)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = RESULTS_DIR / f"resource_finder_prod_report_{stamp}.json"
    html_path = RESULTS_DIR / f"resource_finder_prod_report_{stamp}.html"
    json_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    html_path.write_text(render_html(results, stamp), encoding="utf-8")
    print(f"[ok] wrote {json_path}")
    print(f"[ok] wrote {html_path}")


if __name__ == "__main__":
    asyncio.run(main())
