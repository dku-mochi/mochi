"""유튜브 메타데이터 추출 실험 — URL 만으로 사용자 fallback 없이 어디까지 구제되나.

북극성
------
"사용자가 직접 무언가 해야 하는 것을 최대한 줄인다."
스크린샷에서 단서가 안 나오면 결국 사용자에게 intent 선택·직접입력을 요청(fallback)할 수밖에
없다. 그 전에 **URL → 메타데이터(제목·채널·설명)** 로 한 번 더 구제해서 fallback 비율을
낮출 수 있는가? 가 이 실험의 질문이다.

왜 메타인가 (사전 조사 결론)
----
- Gemini 멀티모달(YouTube URL 직접 입력): 영상 토큰화 ~300 tok/s → 10분=18만 토큰.
  지금은 프리뷰 무료지만 GA 시 비용 폭발 + 프리뷰 의존 위험.
- 자막(youtube-transcript-api): 클라우드 IP 차단 → residential proxy 필수.
  공식 captions.download 는 OAuth + 본인 영상만. → 지속성 취약.
- 메타(oEmbed 무키 + watch page shortDescription): 공식·무키·클라우드 OK·지속가능.
  → 1차 경로로 검증한다. 무거운 경로(자막/멀티모달)는 메타가 불충분할 때의 fallback.

파이프라인
----------
URL → [1] 메타추출 (oEmbed 제목·채널 + watch page 전체설명·길이·자막유무·키워드)
    → [2] flash-lite (영상 못 봄 전제, 메타만으로 intent 분류 + 요약 + 충분도 판정)
    → [3] 집계: 메타추출 성공률 · '메타만으로 충분' 비율(=fallback 회피율) · 길이대별 비교

실행
----
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
    uv run --directory mochi-backend \
    python lab/active/youtube-enrich/youtube_enrich_bench.py

출력 (스크립트와 같은 폴더)
  youtube_enrich_results.json / youtube_enrich_report.md
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Any

import httpx
from google import genai
from google.genai import types

HERE = Path(__file__).parent
RESULTS_JSON = HERE / "youtube_enrich_results.json"
REPORT_MD = HERE / "youtube_enrich_report.md"

MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"
# per 1M tokens, USD — ⚠️ ESTIMATE (extraction 벤치와 동일 단가). 상대 비교용.
PRICING = {"in": 0.10, "out": 0.40}

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

# 데이터셋: (video_id, genre weak label). 제목·채널은 oEmbed 가 채운다.
# 장르 다양성 = 모찌가 실제로 저장될 법한 결: 리뷰/운동/강의/여행/먹방/쇼츠/음악.
DATASET: list[tuple[str, str]] = [
    ("8kYyKpB4R0Y", "tech-review"),
    ("QfOrE_9yh7U", "tech-review"),
    ("H38ach0TmWM", "workout"),
    ("bLtzpPrNOW0", "workout"),
    ("rfscVS0vtbw", "coding-course"),
    ("_uQrJ0TkZlc", "coding-course"),
    ("XDYEDS5nCjw", "travel-vlog"),
    ("ZUCOhSx2O0o", "mukbang"),
    ("PcT5udxSQOs", "travel-vlog"),
    ("q6WEA8SeWYI", "shorts-food"),
    ("NyP7qZX1cXU", "shorts-food"),
    ("9bZkp7q19f0", "music"),
    ("gdZLi9oWNZg", "music"),
]


# ── [1] 메타 추출 (무키, HTTP only) ──────────────────────────────────────────

def _json_str(raw: str) -> str:
    """watch page JSON 안의 이스케이프된 문자열을 정확히 디코딩 (한글·이모지 보존)."""
    try:
        return json.loads(f'"{raw}"')
    except Exception:
        return raw


async def fetch_meta(hc: httpx.AsyncClient, vid: str) -> dict[str, Any]:
    watch_url = f"https://www.youtube.com/watch?v={vid}"
    meta: dict[str, Any] = {"video_id": vid, "url": watch_url}

    # oEmbed (무키): 제목·채널·썸네일 — 깨끗한 1차 소스
    try:
        r = await hc.get(
            "https://www.youtube.com/oembed",
            params={"format": "json", "url": watch_url},
            timeout=10,
        )
        if r.status_code == 200:
            o = r.json()
            meta["title"] = o.get("title")
            meta["channel"] = o.get("author_name")
            meta["thumbnail"] = o.get("thumbnail_url")
        else:
            meta["oembed_status"] = r.status_code
    except Exception as e:  # noqa: BLE001
        meta["oembed_error"] = repr(e)

    # watch page: 전체 설명 / 길이 / 자막유무 / 키워드 (oEmbed 가 안 주는 것)
    try:
        r = await hc.get(watch_url, headers={"User-Agent": UA}, timeout=20, follow_redirects=True)
        html = r.text
        dm = re.search(r'"shortDescription":"((?:[^"\\]|\\.)*)"', html)
        meta["description"] = _json_str(dm.group(1)) if dm else ""
        lm = re.search(r'"lengthSeconds":"(\d+)"', html)
        meta["length_seconds"] = int(lm.group(1)) if lm else None
        meta["has_captions"] = '"captionTracks"' in html
        km = re.search(r'"keywords":\[((?:[^\]]|\\.)*?)\]', html)
        if km:
            try:
                meta["keywords"] = json.loads(f"[{km.group(1)}]")[:10]
            except Exception:  # noqa: BLE001
                meta["keywords"] = []
        if not meta.get("title"):  # oEmbed 실패 시 og:title 폴백
            tm = re.search(r'<meta property="og:title" content="([^"]*)"', html)
            meta["title"] = tm.group(1) if tm else None
    except Exception as e:  # noqa: BLE001
        meta["watch_error"] = repr(e)

    meta["meta_ok"] = bool(meta.get("title"))
    meta["desc_len"] = len(meta.get("description") or "")
    return meta


# ── [2] flash-lite 판정 (메타만 입력) ────────────────────────────────────────

_INTENT_ENUM = ["schedule", "todo", "knowledge", "memo"]

_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "intent": {"type": "string", "enum": _INTENT_ENUM},
        "secondary_intents": {"type": "array", "items": {"type": "string", "enum": _INTENT_ENUM}},
        "summary": {"type": "string"},
        "sufficient": {"type": "boolean"},
        "fallback_reason": {"type": "string"},
        "confidence": {"type": "number"},
    },
    "required": ["intent", "summary", "sufficient", "confidence"],
}

_SYS = """너는 모찌(스크린샷·링크 기록 관리 에이전트)의 분석기다.
사용자가 유튜브 영상을 저장했고, 너에게는 영상 자체가 아니라 메타데이터(제목·채널·설명·길이)만 주어진다.
영상을 재생하거나 자막을 볼 수 없다. 오직 이 메타만으로 판단하라.

4-intent:
- schedule : 특정 시점에 발생/참여하는 사건 (약속, 마감일, 행사)
- todo     : 사용자가 직접 수행해야 할 행동 (구매, 답장, 신청, 시도)
- knowledge: 영구 참조 가치의 정보 (개념, 가이드, 학습 자료)
- memo     : 위 셋에 안 들어가는 정서적·일회적 기록 (영감, 추억, 자랑, 분위기)

판단할 것:
1. intent + secondary_intents (없으면 빈 배열)
2. summary: 메타 기반 한 줄 요약 (한국어)
3. sufficient: 이 메타만으로 "사용자가 왜 저장했는지 / 핵심이 무엇인지"를 모찌가
   검색·분류·대화에 쓸 만큼 충분히 파악되는가? (영상 전체 이해가 아니라 '기록관리 충분성' 기준)
   - 제목·설명이 내용을 충분히 담으면 true.
   - 제목만 있고 설명이 홍보문구·링크·해시태그뿐이라 내용 단서가 없으면 false.
4. fallback_reason: sufficient=false 일 때만 무엇이 빠졌는지 한 줄. true 면 빈 문자열.
5. confidence: 0~1.
"""

_local = threading.local()


def _client() -> genai.Client:
    c = getattr(_local, "client", None)
    if c is None:
        project = os.environ.get("GOOGLE_CLOUD_PROJECT") or "axial-device-460408-i9"
        c = genai.Client(vertexai=True, project=project, location=LOCATION)
        _local.client = c
    return c


def _analyze_sync(meta: dict[str, Any]) -> dict[str, Any]:
    user = (
        f"제목: {meta.get('title')}\n"
        f"채널: {meta.get('channel')}\n"
        f"길이: {meta.get('length_seconds')}초\n"
        f"자막 존재: {meta.get('has_captions')}\n"
        f"키워드: {', '.join(meta.get('keywords') or [])}\n"
        f"설명:\n{(meta.get('description') or '')[:2000]}\n"
    )
    cfg = types.GenerateContentConfig(
        system_instruction=_SYS,
        temperature=0.0,
        response_mime_type="application/json",
        response_schema=_SCHEMA,
    )
    t0 = time.monotonic()
    resp = _client().models.generate_content(model=MODEL, contents=user, config=cfg)
    dt_ms = round((time.monotonic() - t0) * 1000)
    out = json.loads(resp.text)
    um = resp.usage_metadata
    out["_tok_in"] = getattr(um, "prompt_token_count", 0) or 0
    out["_tok_out"] = getattr(um, "candidates_token_count", 0) or 0
    out["_ms"] = dt_ms
    out["_cost"] = round(out["_tok_in"] / 1e6 * PRICING["in"] + out["_tok_out"] / 1e6 * PRICING["out"], 6)
    return out


# ── [3] 집계 · 리포트 ────────────────────────────────────────────────────────

def _bucket(s: int | None) -> str:
    if s is None:
        return "unknown"
    if s < 60:
        return "shorts(<60s)"
    if s < 600:
        return "mid(1-10m)"
    return "long(>10m)"


def _clean(s: str | None, n: int = 60) -> str:
    s = (s or "").replace("|", "/").replace("\n", " ").strip()
    return s[:n] + ("…" if len(s) > n else "")


def build_report(results: list[dict[str, Any]]) -> str:
    ok = [r for r in results if r.get("meta_ok")]
    an = [r for r in ok if r.get("analysis")]
    suf = [r for r in an if r["analysis"].get("sufficient")]
    n = len(results)

    intent_dist: dict[str, int] = {}
    for r in an:
        i = r["analysis"].get("intent", "?")
        intent_dist[i] = intent_dist.get(i, 0) + 1

    # 길이대별 충분율
    buckets: dict[str, list[dict]] = {}
    for r in an:
        buckets.setdefault(_bucket(r.get("length_seconds")), []).append(r)

    avg_cost = sum(r["analysis"]["_cost"] for r in an) / len(an) if an else 0
    avg_ms = sum(r["analysis"]["_ms"] for r in an) / len(an) if an else 0
    avg_in = sum(r["analysis"]["_tok_in"] for r in an) / len(an) if an else 0
    avg_out = sum(r["analysis"]["_tok_out"] for r in an) / len(an) if an else 0

    L: list[str] = []
    L.append("# 유튜브 메타 추출 실험 — URL → 메타만으로 fallback 회피")
    L.append("")
    L.append("> 북극성: **사용자가 직접 해야 할 일을 최대한 줄인다.** "
             "메타(oEmbed 제목·채널 + watch page 전체설명·길이·자막유무)만으로 "
             "intent 분류·요약이 되는가, 그래서 사용자 fallback 을 얼마나 피하는가.")
    L.append("")
    L.append("> ⚠️ 비용 단가는 추정치(flash-lite, extraction 벤치와 동일). 메타는 전부 무키·공식 경로.")
    L.append("")
    L.append("## 핵심 지표")
    L.append("")
    L.append(f"- **메타 추출 성공**: {len(ok)}/{n}")
    L.append(f"- **분석 완료**: {len(an)}/{n}")
    pct = f"{len(suf) / len(an) * 100:.0f}%" if an else "—"
    L.append(f"- **메타만으로 충분(sufficient)**: {len(suf)}/{len(an)} ({pct}) "
             f"← = 사용자 fallback 회피율")
    L.append(f"- **평균 비용**: ${avg_cost:.6f} / 건  (tok_in {avg_in:.0f}, tok_out {avg_out:.0f})")
    L.append(f"- **평균 지연**: {avg_ms:.0f} ms")
    L.append(f"- **intent 분포**: " + ", ".join(f"{k} {v}" for k, v in sorted(intent_dist.items())))
    L.append("")
    L.append("## 길이대별 충분율 (영상 길이가 변수인가)")
    L.append("")
    L.append("| 길이대 | 충분/전체 | 비고 |")
    L.append("|---|---|---|")
    for b in ["shorts(<60s)", "mid(1-10m)", "long(>10m)", "unknown"]:
        rs = buckets.get(b)
        if not rs:
            continue
        s = sum(1 for r in rs if r["analysis"].get("sufficient"))
        L.append(f"| {b} | {s}/{len(rs)} | |")
    L.append("")
    L.append("## 영상별 상세")
    L.append("")
    L.append("| genre | 제목 | 채널 | 길이s | CC | 설명자 | intent | 충분? | 요약 / fallback 이유 |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        if not r.get("meta_ok"):
            L.append(f"| {r.get('genre')} | (메타실패 {r.get('video_id')}) | | | | | | ❌ | "
                     f"{r.get('oembed_error') or r.get('watch_error') or r.get('oembed_status')} |")
            continue
        a = r.get("analysis") or {}
        cc = "✓" if r.get("has_captions") else "✗"
        suff = "✅" if a.get("sufficient") else "🙋"
        note = a.get("summary", "") if a.get("sufficient") else f"⚠️ {a.get('fallback_reason', '')}"
        L.append(
            f"| {r.get('genre')} | {_clean(r.get('title'), 42)} | {_clean(r.get('channel'), 18)} "
            f"| {r.get('length_seconds')} | {cc} | {r.get('desc_len')} "
            f"| {a.get('intent', '?')} | {suff} | {_clean(note, 70)} |"
        )
    L.append("")
    return "\n".join(L)


async def main() -> None:
    print(f"▶ {len(DATASET)} videos — 메타 추출 + flash-lite 판정")
    async with httpx.AsyncClient() as hc:
        sem = asyncio.Semaphore(6)

        async def one(vid: str, genre: str) -> dict[str, Any]:
            async with sem:
                meta = await fetch_meta(hc, vid)
                meta["genre"] = genre
                status = "ok" if meta["meta_ok"] else "META-FAIL"
                if meta["meta_ok"]:
                    try:
                        meta["analysis"] = await asyncio.to_thread(_analyze_sync, meta)
                        a = meta["analysis"]
                        status = f"{a['intent']} | suf={a['sufficient']} | {a['_ms']}ms"
                    except Exception as e:  # noqa: BLE001
                        meta["analysis_error"] = repr(e)
                        status = f"ANALYZE-FAIL {e!r}"
                print(f"  · {vid} [{genre}] {status}")
                return meta

        results = await asyncio.gather(*(one(v, g) for v, g in DATASET))

    RESULTS_JSON.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    REPORT_MD.write_text(build_report(results), encoding="utf-8")
    print(f"\n✓ 결과: {RESULTS_JSON.name} / {REPORT_MD.name}")


if __name__ == "__main__":
    asyncio.run(main())
