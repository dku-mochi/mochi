"""X 비공식 syndication 으로 게시물(post) 수준 복원 측정 (exp3) — 베팅 전 리스크 실측.

배경:
  exp2 에서 X 의 무키 상한은 profile 로 나왔다. 하지만 비공식
  `syndication.twitter.com/srv/timeline-profile/screen-name/{handle}` 이 살아있어
  `__NEXT_DATA__` 에 최근 트윗(full_text·id_str·permalink·created_at)을 무키로 싣는다.
  → `handle → 최근 트윗 → 캡쳐 텍스트 매칭 → x.com/{handle}/status/{id}` 로 post 복원이
  기술적으로 가능. youtube-enrich 가 기각한 비공식 스크랩과 같은 리스크 클래스라, 베팅 전에
  세 가지를 실측한다:
    (1) 생존성  — 엔드포인트가 응답하는가 (이 머신 기준. 클라우드 Run/GCP IP 는 별도 확인 — 차단 가능)
    (2) 최근성 깊이 — 몇 개·얼마나 과거까지 커버하나 (오래된 캡쳐는 못 찾음)
    (3) 매칭 정확도 — 캡쳐 본문(부분 OCR)으로 정확한 트윗을 top-1 으로 집어내는가

방법:
  - 기본: 공인 공개 계정 several 개에 대해 타임라인을 받아 (2)(3) 자기일관성 평가 —
    각 트윗의 full_text 를 ~50자 부분 OCR 로 흉내내(절단/공백노이즈) 같은 타임라인에서
    top-1 매칭이 원본 id 로 돌아오는지 측정.
  - 수동: --handle 와 --text 로 실제 1건 복원 (캡쳐 본문을 직접 주는 시뮬레이션).

실행 (repo 루트에서):
  uv run --project mochi-backend python lab/active/capture-url-recovery/exp3_x_syndication.py
  uv run --project mochi-backend python lab/active/capture-url-recovery/exp3_x_syndication.py \\
    --handle elonmusk --text "SpaceX AI Satellites"

결과: results/exp3_YYYYMMDD_HHMMSS.json
"""
import argparse
import json
import re
import sys
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

import httpx

sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"

# 검색 스크랩은 서버측 단계라 데스크톱 UA (timeline HTML 에 __NEXT_DATA__ 가 실린다).
SCRAPE_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
NEXT_DATA_RE = re.compile(
    r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.S
)
TCO_RE = re.compile(r"https?://t\.co/\S+")

HANDLES = ["elonmusk", "nasa", "naval"]
SAMPLE_PER_HANDLE = 12  # 매칭 평가용 표본
OCR_PREFIX_CHARS = 50  # 부분 OCR 흉내: 본문 앞부분만 잡힌 캡쳐


def fetch_timeline(client: httpx.Client, handle: str) -> tuple[int, list[dict]]:
    url = f"https://syndication.twitter.com/srv/timeline-profile/screen-name/{handle}"
    resp = client.get(url, headers={"User-Agent": SCRAPE_UA})
    m = NEXT_DATA_RE.search(resp.text)
    if not m:
        return resp.status_code, []
    data = json.loads(m.group(1))
    entries = _find_entries(data)
    tweets = []
    for e in entries:
        if e.get("type") != "tweet":
            continue
        t = e.get("content", {}).get("tweet", {})
        tid = t.get("id_str") or e.get("entry_id", "").replace("tweet-", "")
        text = t.get("full_text") or t.get("text") or ""
        if not tid or not text:
            continue
        screen = (t.get("user") or {}).get("screen_name") or handle
        tweets.append(
            {
                "id": tid,
                "text": text,
                "url": f"https://x.com/{screen}/status/{tid}",
                "created_at": t.get("created_at"),
            }
        )
    return resp.status_code, tweets


def _find_entries(obj) -> list:
    if isinstance(obj, dict):
        if isinstance(obj.get("entries"), list):
            return obj["entries"]
        for v in obj.values():
            found = _find_entries(v)
            if found:
                return found
    elif isinstance(obj, list):
        for x in obj:
            found = _find_entries(x)
            if found:
                return found
    return []


def _norm(s: str) -> str:
    s = TCO_RE.sub("", s)  # 단축 URL 은 캡쳐 화면에 안 보이니 매칭에서 제외
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def best_match(query: str, tweets: list[dict]) -> tuple[dict | None, float]:
    q = _norm(query)
    best, score = None, 0.0
    for t in tweets:
        r = SequenceMatcher(None, q, _norm(t["text"])).ratio()
        if r > score:
            best, score = t, r
    return best, round(score, 3)


def eval_handle(client: httpx.Client, handle: str) -> dict:
    status, tweets = fetch_timeline(client, handle)
    row: dict = {"handle": handle, "status": status, "count": len(tweets)}
    if not tweets:
        return row
    row["newest"] = tweets[0]["created_at"]
    row["oldest"] = tweets[-1]["created_at"]

    # 매칭 자기일관성: 본문 앞 OCR_PREFIX_CHARS 자만으로 원본 트윗을 집어내는가.
    sample = tweets[:SAMPLE_PER_HANDLE]
    hits, scores = 0, []
    for t in sample:
        captured = _norm(t["text"])[:OCR_PREFIX_CHARS]
        if len(captured) < 10:
            continue
        match, score = best_match(captured, tweets)
        scores.append(score)
        if match and match["id"] == t["id"]:
            hits += 1
    n = len(scores)
    row["match_eval"] = {
        "sampled": n,
        "top1_correct": hits,
        "top1_accuracy": round(hits / n, 2) if n else None,
        "avg_score": round(sum(scores) / n, 3) if n else None,
    }
    return row


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handle", help="단일 복원: X handle (@ 없이)")
    parser.add_argument("--text", help="단일 복원: 캡쳐에서 읽은 본문")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(exist_ok=True)
    with httpx.Client(follow_redirects=True, timeout=20) as client:
        if args.handle and args.text:
            status, tweets = fetch_timeline(client, args.handle.lstrip("@"))
            match, score = best_match(args.text, tweets)
            out = {
                "mode": "manual",
                "handle": args.handle,
                "query": args.text,
                "timeline_status": status,
                "timeline_count": len(tweets),
                "best_match_url": match["url"] if match else None,
                "best_match_text": match["text"] if match else None,
                "score": score,
            }
            print(json.dumps(out, ensure_ascii=False, indent=2))
        else:
            rows = [eval_handle(client, h) for h in HANDLES]
            out = {"mode": "self_consistency", "results": rows}
            for r in rows:
                me = r.get("match_eval", {})
                print(
                    f"  @{r['handle']:10s} status={r['status']} count={r['count']:3d} "
                    f"oldest={r.get('oldest')}  top1={me.get('top1_accuracy')} "
                    f"avg_score={me.get('avg_score')}"
                )

    stamp = f"{datetime.now():%Y%m%d_%H%M%S}"
    path = RESULTS_DIR / f"exp3_{stamp}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n결과 저장: {path}")


if __name__ == "__main__":
    main()
