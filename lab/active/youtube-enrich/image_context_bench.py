"""유튜브 스크린샷 → [1] 이미지 맥락 추출, [2] 부족 시 URL 복원 실험.

북극성
------
"사용자가 직접 무언가 해야 하는 것을 최대한 줄인다."
앞 실험(youtube_enrich_bench)은 URL 이 있을 때 메타만으로 충분함을 보였다. 여기선
URL 이 **없는** 스크린샷에서 시작해 두 단계를 순서대로 검증한다:

  [1] 이미지만으로 맥락(제목·채널·intent·요약)이 충분히 추출되는가?
      → 되면 URL 자체가 불필요 (사용자 fallback 0).
  [2] 부족하거나 더 풍부한 맥락이 필요하면, 이미지 단서(제목·채널)로 원본 URL 을
      복원할 수 있는가? = 무키 youtube 검색 → 첫 videoId → oEmbed 로 검증.
      → 복원되면 앞 실험의 메타 경로로 연결.

URL 복원 검증
----
복원한 videoId 의 oEmbed 제목이 비전이 읽은 제목과 키워드로 겹치는가(자카드)로
"정확히 그 영상을 찾았는가"를 자동 근사한다. ground truth videoId 가 없으므로 근사치다.

데이터: lab/data/screenshot/youtube/*.PNG  (URL 없는 실제 스크린샷)

실행
----
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
    uv run --directory mochi-backend \
    python lab/active/youtube-enrich/image_context_bench.py

출력 (스크립트와 같은 폴더)
  image_context_results.json / image_context_report.md
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
LAB_ROOT = HERE.parent.parent  # lab/
SHOT_DIR = LAB_ROOT / "data" / "screenshot" / "youtube"
RESULTS_JSON = HERE / "image_context_results.json"
REPORT_MD = HERE / "image_context_report.md"

MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"
PRICING = {"in": 0.10, "out": 0.40}  # per 1M tok, USD — 추정, 상대 비교용
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

_INTENT_ENUM = ["schedule", "todo", "knowledge", "memo"]


# ── [1] Gemini Vision 맥락 추출 ───────────────────────────────────────────────

_VISION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "screen_type": {"type": "string"},          # shorts / video / search / home / comments / etc
        "extracted_title": {"type": "string"},        # 화면에서 읽은 영상 제목/주제
        "extracted_channel": {"type": "string"},       # @handle 또는 채널명
        "visible_text": {"type": "string"},            # 오버레이/자막/캡션 핵심
        "intent": {"type": "string", "enum": _INTENT_ENUM},
        "summary": {"type": "string"},
        "context_sufficient": {"type": "boolean"},
        "needs_url_reason": {"type": "string"},
        "search_query": {"type": "string"},            # URL 복원용 검색어 (채널 + 제목 키워드)
        "confidence": {"type": "number"},
    },
    "required": ["screen_type", "extracted_title", "extracted_channel", "intent",
                 "summary", "context_sufficient", "search_query", "confidence"],
}

_SYS = """너는 모찌(스크린샷·링크 기록 관리 에이전트)의 분석기다.
사용자가 유튜브 화면을 스크린샷으로 저장했다. URL 은 없고 이미지만 있다.
화면을 보고 추출하라:

- screen_type: shorts / video(가로 일반 재생) / search / home / comments / etc
- extracted_title: 화면에 보이는 영상 제목 또는 핵심 주제 (쇼츠면 오버레이/캡션 텍스트 포함)
- extracted_channel: @handle 또는 채널명 (보이면, 없으면 빈 문자열)
- visible_text: 오버레이·자막·캡션의 핵심 텍스트 (사용자 관심의 단서)

4-intent:
- schedule : 특정 시점에 발생/참여하는 사건 (약속, 마감일, 행사)
- todo     : 사용자가 직접 수행해야 할 행동 (구매, 답장, 신청, 시도)
- knowledge: 영구 참조 가치의 정보 (개념, 가이드, 학습 자료)
- memo     : 위 셋에 안 들어가는 정서적·일회적 기록 (영감, 추억, 자랑, 분위기)

- intent + summary(한국어 한 줄)
- context_sufficient: 이 이미지만으로 "사용자가 왜 저장했는지 / 무슨 내용인지"를
  모찌가 검색·분류·대화에 쓸 만큼 충분히 파악되는가? (영상 전체 이해가 아니라 기록관리 충분성)
- needs_url_reason: context_sufficient=false 일 때만, 원본 영상을 찾아야 하는 이유 한 줄
  (예: 제목이 잘려 모호 / 영상 전체 내용이 필요 / 채널·제목 식별 불가). true 면 빈 문자열.
- search_query: 원본 영상을 youtube 에서 찾기 위한 최적 검색어. 채널명 + 제목 핵심 키워드 조합.
- confidence: 0~1.
"""

_local = threading.local()


def _client() -> genai.Client:
    c = getattr(_local, "client", None)
    if c is None:
        project = os.environ.get("GOOGLE_CLOUD_PROJECT") or "axial-device-460408-i9"
        c = genai.Client(vertexai=True, project=project, location=LOCATION)
        _local.client = c
    return c


def _vision_sync(img_bytes: bytes) -> dict[str, Any]:
    part = types.Part.from_bytes(data=img_bytes, mime_type="image/png")
    cfg = types.GenerateContentConfig(
        system_instruction=_SYS,
        temperature=0.0,
        response_mime_type="application/json",
        response_schema=_VISION_SCHEMA,
    )
    t0 = time.monotonic()
    resp = _client().models.generate_content(model=MODEL, contents=[part, "이 화면을 분석하라."], config=cfg)
    dt_ms = round((time.monotonic() - t0) * 1000)
    out = json.loads(resp.text)
    um = resp.usage_metadata
    out["_tok_in"] = getattr(um, "prompt_token_count", 0) or 0
    out["_tok_out"] = getattr(um, "candidates_token_count", 0) or 0
    out["_ms"] = dt_ms
    out["_cost"] = round(out["_tok_in"] / 1e6 * PRICING["in"] + out["_tok_out"] / 1e6 * PRICING["out"], 6)
    return out


# ── [2] URL 복원 (무키 youtube 검색 → videoId → oEmbed) ───────────────────────

async def recover_url(hc: httpx.AsyncClient, query: str) -> dict[str, Any]:
    out: dict[str, Any] = {"query": query, "recovered": False}
    try:
        r = await hc.get(
            "https://www.youtube.com/results",
            params={"search_query": query},
            headers={"User-Agent": UA},
            timeout=15,
        )
        ids: list[str] = []
        for m in re.finditer(r'"videoId":"([\w-]{11})"', r.text):
            if m.group(1) not in ids:
                ids.append(m.group(1))
        out["candidates"] = ids[:5]
        if not ids:
            return out
        vid = ids[0]
        out["video_id"] = vid
        out["url"] = f"https://www.youtube.com/watch?v={vid}"
        # oEmbed 로 복원 검증
        ro = await hc.get(
            "https://www.youtube.com/oembed",
            params={"format": "json", "url": out["url"]},
            timeout=10,
        )
        if ro.status_code == 200:
            o = ro.json()
            out["recovered_title"] = o.get("title")
            out["recovered_channel"] = o.get("author_name")
            out["recovered"] = True
        else:
            out["oembed_status"] = ro.status_code
    except Exception as e:  # noqa: BLE001
        out["error"] = repr(e)
    return out


def title_match(a: str | None, b: str | None) -> float:
    """비전 제목 ↔ 복원 제목 키워드 자카드 (표현 달라도 키워드 겹침 측정)."""
    def norm(s: str | None) -> set[str]:
        toks = re.sub(r"[^\w가-힣]", " ", (s or "").lower()).split()
        return {t for t in toks if len(t) > 1}
    A, B = norm(a), norm(b)
    if not A or not B:
        return 0.0
    return round(len(A & B) / len(A | B), 2)


# ── [3] 집계 · 리포트 ────────────────────────────────────────────────────────

def _clean(s: str | None, n: int = 40) -> str:
    s = (s or "").replace("|", "/").replace("\n", " ").strip()
    return s[:n] + ("…" if len(s) > n else "")


MATCH_OK = 0.3  # 복원 정확 판정 임계 (키워드 자카드)


def build_report(results: list[dict[str, Any]]) -> str:
    n = len(results)
    viz = [r for r in results if r.get("vision")]
    suf = [r for r in viz if r["vision"].get("context_sufficient")]
    rec = [r for r in results if r.get("recover", {}).get("recovered")]
    rec_ok = [r for r in rec if title_match(
        r["vision"].get("extracted_title") if r.get("vision") else None,
        r["recover"].get("recovered_title")) >= MATCH_OK]

    avg_cost = sum(r["vision"]["_cost"] for r in viz) / len(viz) if viz else 0
    avg_ms = sum(r["vision"]["_ms"] for r in viz) / len(viz) if viz else 0
    avg_in = sum(r["vision"]["_tok_in"] for r in viz) / len(viz) if viz else 0

    L: list[str] = []
    L.append("# 유튜브 스크린샷 — 이미지 맥락 추출 + URL 복원")
    L.append("")
    L.append("> 북극성: **사용자가 직접 할 일을 최대한 줄인다.** URL 없는 스크린샷에서 "
             "[1] 이미지만으로 맥락이 충분한가, [2] 부족하면 단서로 원본 URL 을 복원할 수 있는가.")
    L.append("")
    L.append("> ⚠️ 비용 단가 추정치(flash-lite Vision). URL 복원은 무키 youtube 검색→oEmbed. "
             f"복원 정확도 = 비전 제목↔복원 제목 키워드 자카드 ≥ {MATCH_OK} (근사).")
    L.append("")
    L.append("## 핵심 지표")
    L.append("")
    L.append(f"- **표본**: {n} 장 (URL 없는 실제 스크린샷)")
    spct = f"{len(suf) / len(viz) * 100:.0f}%" if viz else "—"
    L.append(f"- **[1] 이미지만으로 맥락 충분**: {len(suf)}/{len(viz)} ({spct}) ← URL 없이 끝나는 비율")
    rpct = f"{len(rec) / n * 100:.0f}%" if n else "—"
    L.append(f"- **[2] URL 복원 성공(videoId 찾음)**: {len(rec)}/{n} ({rpct})")
    opct = f"{len(rec_ok) / len(rec) * 100:.0f}%" if rec else "—"
    L.append(f"- **복원 정확(제목 매칭 ≥{MATCH_OK})**: {len(rec_ok)}/{len(rec)} ({opct}) ← 올바른 영상 복원율")
    L.append(f"- **Vision 평균 비용**: ${avg_cost:.6f}/장 (tok_in {avg_in:.0f}), 지연 {avg_ms:.0f}ms")
    L.append("")
    L.append("## 이미지별 상세")
    L.append("")
    L.append("| 파일 | screen | 비전 제목 | 채널 | intent | 충분? | 복원 videoId | 복원 제목 | match |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        v = r.get("vision") or {}
        rc = r.get("recover") or {}
        suff = "✅" if v.get("context_sufficient") else "🙋"
        mt = title_match(v.get("extracted_title"), rc.get("recovered_title")) if rc.get("recovered") else "-"
        L.append(
            f"| {r['file']} | {v.get('screen_type', '?')} | {_clean(v.get('extracted_title'), 34)} "
            f"| {_clean(v.get('extracted_channel'), 16)} | {v.get('intent', '?')} | {suff} "
            f"| {rc.get('video_id', '—')} | {_clean(rc.get('recovered_title'), 30)} | {mt} |"
        )
    L.append("")
    L.append("## 케이스 노트 (비전 요약 · 불충분 사유)")
    L.append("")
    for r in results:
        v = r.get("vision") or {}
        L.append(f"- **{r['file']}** [{v.get('intent')}] {_clean(v.get('summary'), 80)}")
        if not v.get("context_sufficient"):
            L.append(f"  - 🙋 URL 필요: {v.get('needs_url_reason')}")
        rc = r.get("recover") or {}
        if rc.get("recovered"):
            L.append(f"  - 🔗 복원: {rc.get('recovered_title')} / {rc.get('recovered_channel')} "
                     f"(query: \"{v.get('search_query')}\")")
        elif rc.get("error") or rc.get("candidates") == []:
            L.append(f"  - ⚠️ 복원 실패: {rc.get('error') or 'videoId 없음'}")
    L.append("")
    return "\n".join(L)


async def main() -> None:
    files = sorted(SHOT_DIR.glob("*.PNG")) + sorted(SHOT_DIR.glob("*.png"))
    print(f"▶ {len(files)} screenshots — Vision 맥락 추출 + URL 복원")
    async with httpx.AsyncClient() as hc:
        sem = asyncio.Semaphore(4)

        async def one(p: Path) -> dict[str, Any]:
            async with sem:
                rec: dict[str, Any] = {"file": p.name}
                try:
                    img = p.read_bytes()
                    v = await asyncio.to_thread(_vision_sync, img)
                    rec["vision"] = v
                except Exception as e:  # noqa: BLE001
                    rec["vision_error"] = repr(e)
                    print(f"  · {p.name} VISION-FAIL {e!r}")
                    return rec
                q = v.get("search_query") or f"{v.get('extracted_channel')} {v.get('extracted_title')}"
                rec["recover"] = await recover_url(hc, q)
                mt = title_match(v.get("extracted_title"), rec["recover"].get("recovered_title"))
                print(f"  · {p.name} [{v['screen_type']}/{v['intent']}] suf={v['context_sufficient']} "
                      f"| recover={rec['recover'].get('recovered')} match={mt}")
                return rec

        results = await asyncio.gather(*(one(p) for p in files))

    RESULTS_JSON.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    REPORT_MD.write_text(build_report(results), encoding="utf-8")
    print(f"\n✓ 결과: {RESULTS_JSON.name} / {REPORT_MD.name}")


if __name__ == "__main__":
    asyncio.run(main())
