"""캡처 단서 → best-effort 원문 URL 복원 실험 (exp2) — 플랫폼별로 어느 수준까지 URL 을 만들 수 있는가.

배경:
  사용자가 고른 목표는 "best-effort": 정확한 게시물 deep-link 가 안 되면 프로필/검색 링크라도
  노출. 플랫폼마다 무키(키 없는) 복원 가능 수준이 다르다 — 이 실험이 그 상한을 실측한다.

  복원 tier (높을수록 좋음):
    post    : 그 게시물/영상의 정확한 URL (예: youtube watch?v=..., x.com/u/status/123)
    profile : 작성자 프로필 URL (그 게시물은 아니지만 작성자까지 도달)
    search  : 검색어가 들어간 검색 결과 URL (마지막 폴백)
    none    : 단서 부족으로 아무것도 못 만듦

  가설(youtube-enrich 연장): YouTube 는 무키 검색이 살아있어 post 수준 가능.
  X·Threads 는 게시물 ID 가 화면에 없고 무키 게시물 검색 경로가 없어 profile 이 상한.

방법:
  exp1 결과(최신 exp1_*.json)의 단서 — 또는 아래 DEFAULT_CASES(공인 공개 계정) — 에 대해
  플랫폼별 복원을 시도하고, 만들어진 URL 을 iPhone Safari UA 로 GET 하여 status·최종 URL·
  도달 tier 를 기록한다. 봇 차단(403/429 등) ≠ 사용자 브라우저 실패 — 최종 UX 는 출력된
  마크다운 링크 목록을 실기기에서 직접 탭해 확인한다.

실행 (repo 루트에서):
  uv run --project mochi-backend python lab/active/capture-url-recovery/exp2_url_recovery.py
  # exp1 결과 대신 기본 공개 케이스로 도달성만 빠르게 보려면:
  uv run --project mochi-backend python lab/active/capture-url-recovery/exp2_url_recovery.py --defaults

결과: results/exp2_YYYYMMDD_HHMMSS.json + results/exp2_links_*.md (실기기 수동 확인용)
"""
import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import httpx

sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"

# 사용자가 링크를 여는 환경과 동일하게 — iPhone Safari (최종 URL 도달성 확인용).
UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"
)
HEADERS = {"User-Agent": UA, "Accept-Language": "ko-KR,ko;q=0.9"}

# YouTube 검색→videoId 스크랩은 백엔드 서버측 단계라 사용자 UA 와 무관 — 데스크톱 UA 라야
# 결과 HTML 에 ytInitialData(`"videoId":"..."`)가 실린다. 모바일(m.youtube.com)은 안 실림.
SCRAPE_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

# exp1 없이 도달성 자체를 검증하기 위한 공인 공개 계정 케이스.
DEFAULT_CASES = [
    {
        "platform": "youtube",
        "handle": None,
        "author": "HYBE LABELS",
        "title": "NewJeans (뉴진스) 'Hype Boy' Official MV",
        "post_text": None,
        "search_query": "뉴진스 Hype Boy official MV HYBE LABELS",
    },
    {
        "platform": "x",
        "handle": "@elonmusk",
        "author": "Elon Musk",
        "title": None,
        "post_text": "Starship test flight update",
        "search_query": "Elon Musk Starship test flight",
    },
    {
        "platform": "threads",
        "handle": "@zuck",
        "author": "Mark Zuckerberg",
        "title": None,
        "post_text": "new feature rollout",
        "search_query": "zuck threads new feature",
    },
]

YOUTUBE_ID_RE = re.compile(r'"videoId":"([0-9A-Za-z_-]{11})"')


def _clean_handle(handle: str | None) -> str | None:
    if not handle:
        return None
    h = handle.strip().lstrip("@").strip()
    return h or None


def _get(client: httpx.Client, url: str) -> dict:
    try:
        resp = client.get(url)
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        return {"url": url, "error": str(e)[:150]}
    return {
        "url": url,
        "status": resp.status_code,
        "final_url": str(resp.url),
        "body_bytes": len(resp.content),
    }


def recover_youtube(client: httpx.Client, case: dict) -> dict:
    """검색 → 첫 videoId → watch URL → oEmbed 검증. youtube-enrich 무키 경로 재현."""
    q = case.get("search_query") or " ".join(
        x for x in [case.get("author"), case.get("title")] if x
    )
    out: dict = {"tier_attempts": []}
    if not q:
        out["recover_level"] = "none"
        return out

    search_url = f"https://www.youtube.com/results?search_query={quote(q)}"
    video_id = None
    try:
        resp = client.get(search_url, headers={"User-Agent": SCRAPE_UA})
        search = {
            "url": search_url,
            "status": resp.status_code,
            "final_url": str(resp.url),
            "body_bytes": len(resp.content),
        }
        m = YOUTUBE_ID_RE.search(resp.text)
        video_id = m.group(1) if m else None
    except Exception as e:  # noqa: BLE001 — 실험: 실패 자체가 데이터
        search = {"url": search_url, "error": str(e)[:150]}
    out["tier_attempts"].append({"tier": "search", **search})

    if video_id:
        watch_url = f"https://www.youtube.com/watch?v={video_id}"
        oembed_url = "https://www.youtube.com/oembed?format=json&url=" + quote(watch_url)
        oembed = _get(client, oembed_url)
        out["video_id"] = video_id
        out["watch_url"] = watch_url
        out["oembed"] = oembed
        out["recover_level"] = "post" if oembed.get("status") == 200 else "search"
        out["best_url"] = watch_url if oembed.get("status") == 200 else search_url
    else:
        out["recover_level"] = "search"
        out["best_url"] = search_url
    return out


def recover_profile_platform(client: httpx.Client, case: dict, profile_tmpl: str) -> dict:
    """X/Threads: handle → 프로필 URL(상한). 게시물 deep-link 무키 경로 없음 → 검색 폴백."""
    out: dict = {"tier_attempts": []}
    handle = _clean_handle(case.get("handle"))
    if handle:
        profile_url = profile_tmpl.format(handle=handle)
        prof = _get(client, profile_url)
        out["tier_attempts"].append({"tier": "profile", **prof})
        out["recover_level"] = "profile"
        out["best_url"] = profile_url

    q = case.get("search_query")
    if q:
        search_url = f"https://www.google.com/search?q={quote(q)}"
        out["tier_attempts"].append({"tier": "search", **_get(client, search_url)})
        out.setdefault("recover_level", "search")
        out.setdefault("best_url", search_url)

    out.setdefault("recover_level", "none")
    return out


def recover(client: httpx.Client, case: dict) -> dict:
    platform = case.get("platform")
    if platform == "youtube":
        return recover_youtube(client, case)
    if platform == "x":
        return recover_profile_platform(client, case, "https://x.com/{handle}")
    if platform == "threads":
        return recover_profile_platform(client, case, "https://www.threads.net/@{handle}")
    return {"recover_level": "none", "tier_attempts": []}


def latest_exp1_cases() -> list[dict]:
    files = sorted(RESULTS_DIR.glob("exp1_*.json"))
    if not files:
        return []
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    cases: list[dict] = []
    for row in data["results"]:
        # 마지막(더 강한) 추출 모델 결과를 단서로 채택.
        for value in reversed(list(row.values())):
            if isinstance(value, dict) and value.get("is_social_post") and value.get("platform") != "none":
                cases.append(
                    {
                        "case": row.get("case"),
                        "platform": value.get("platform"),
                        "handle": value.get("handle"),
                        "author": value.get("author"),
                        "title": value.get("title"),
                        "post_text": value.get("post_text"),
                        "search_query": value.get("search_query"),
                    }
                )
                break
    return cases


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--defaults", action="store_true", help="exp1 결과 무시하고 공개 케이스로")
    args = parser.parse_args()

    cases = DEFAULT_CASES if args.defaults else (latest_exp1_cases() or DEFAULT_CASES)
    print(f"케이스 {len(cases)}건 복원 시도")

    results = []
    md_lines = ["# exp2 복원 URL — 실기기 수동 확인 목록", ""]
    with httpx.Client(headers=HEADERS, follow_redirects=True, timeout=15) as client:
        for case in cases:
            rec = recover(client, case)
            row = {**case, "recovery": rec}
            results.append(row)
            label = case.get("case") or f"{case['platform']}:{case.get('handle') or case.get('author')}"
            print(f"  [{rec['recover_level']:7s}] {label[:40]:42s} → {rec.get('best_url')}")
            md_lines.append(f"## {label} ({case['platform']})")
            md_lines.append(f"- recover_level: **{rec['recover_level']}**")
            if rec.get("best_url"):
                md_lines.append(f"- [best_url]({rec['best_url']})")
            md_lines.append("")

    by_level: dict[str, int] = {}
    by_platform_level: dict[str, dict[str, int]] = {}
    for r in results:
        lvl = r["recovery"]["recover_level"]
        plat = r["platform"]
        by_level[lvl] = by_level.get(lvl, 0) + 1
        by_platform_level.setdefault(plat, {})
        by_platform_level[plat][lvl] = by_platform_level[plat].get(lvl, 0) + 1

    summary = {"by_level": by_level, "by_platform_level": by_platform_level}

    RESULTS_DIR.mkdir(exist_ok=True)
    stamp = f"{datetime.now():%Y%m%d_%H%M%S}"
    out = RESULTS_DIR / f"exp2_{stamp}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    md = RESULTS_DIR / f"exp2_links_{stamp}.md"
    md.write_text("\n".join(md_lines), encoding="utf-8")
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}\n수동 확인 목록: {md}")


if __name__ == "__main__":
    main()
