"""recoverYoutubeUrl — 이미지 단서(채널+제목)로 원본 유튜브 URL 을 회수하는 결정적 tool.

배경 (lab/active/shopping-product-link FINDINGS, journal 2026-06-14):
  "영상 속 추천 리스트"(인스타·유튜브가 추천한 구체 제품을 캡처가 텍스트로 못 가짐)는
  텍스트 검색으로 영영 못 찾는다 → 답은 검색이 아니라 **원본 영상 URL 회수**. 출처앱이
  YouTube 이고 화면이 영상/쇼츠/댓글일 때, 메인 에이전트가 이미지에서 읽은 채널+제목을
  query 로 넘기면 이 tool 이 결정적으로(LLM 없이) 원본 watch URL 을 찾아 검증한다.

정본: lab/archive/youtube-enrich/image_context_bench.py 의 recover_url
  (무키 youtube `results` 검색 → 첫 videoId → oEmbed 로 복원 검증). 데스크톱 UA 필수
  (모바일 UA 는 ytInitialData 미포함). LLM 호출 없음 → ToolUsage 는 latency 만.
"""

import asyncio
import re
import time
from typing import Any

import httpx
from pydantic import BaseModel

from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolName, ToolUsage

log = get_logger("agent.tool.youtube_recover")

# 데스크톱 UA — 모바일 UA 는 검색 결과 HTML 에 videoId(ytInitialData)를 안 싣는다.
_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
_VIDEO_ID_RE = re.compile(r'"videoId":"([\w-]{11})"')
_SEARCH_URL = "https://www.youtube.com/results"
_OEMBED_URL = "https://www.youtube.com/oembed"
_MAX_QUERY_LEN = 120     # 검색어 길이 상한 — 외부 검색 전 bound
_TOP_K = 5               # oembed 로 검증·재랭킹할 후보 수
_CHANNEL_MATCH_MIN = 0.34  # 채널명 토큰 자카드 임계


class YoutubeRecoverInput(BaseModel):
    query: str  # 화면에서 읽은 영상 제목 키워드 (원본 영상 검색어)
    channel_hint: str | None = None  # 화면에서 읽은 채널명(@핸들 포함) — 후보 재랭킹 신호


class YoutubeRecoverOutput(BaseModel):
    recovered: bool
    url: str | None = None
    video_id: str | None = None
    candidates: list[str] = []
    recovered_title: str | None = None
    recovered_channel: str | None = None


class RecoverYoutubeUrlTool(Tool[YoutubeRecoverInput, YoutubeRecoverOutput]):
    """이미지 단서로 원본 유튜브 watch URL 을 회수(무키 검색→videoId→oEmbed 검증).

    실패(검색 0건·네트워크 오류)는 예외가 아니라 ``recovered=False`` 로 반환해 모델이
    "복원 안 됨"을 보고 finalize 로 진행하게 한다(되먹임).
    """

    name = ToolName.RECOVER_YOUTUBE_URL
    input_model = YoutubeRecoverInput
    output_model = YoutubeRecoverOutput

    async def run(
        self, payload: YoutubeRecoverInput
    ) -> tuple[YoutubeRecoverOutput, ToolUsage]:
        started = time.perf_counter()
        out = await self._recover(payload.query[:_MAX_QUERY_LEN], payload.channel_hint)
        usage = ToolUsage(latency_ms=int((time.perf_counter() - started) * 1000))
        return out, usage

    async def _recover(
        self, query: str, channel_hint: str | None
    ) -> YoutubeRecoverOutput:
        try:
            async with httpx.AsyncClient(timeout=15) as hc:
                r = await hc.get(
                    _SEARCH_URL,
                    params={"search_query": query},
                    headers={"User-Agent": _UA},
                )
                ids: list[str] = []
                for m in _VIDEO_ID_RE.finditer(r.text):
                    if m.group(1) not in ids:
                        ids.append(m.group(1))
                    if len(ids) >= _TOP_K:
                        break
                if not ids:
                    return YoutubeRecoverOutput(recovered=False, candidates=[])

                # 후보 top_k 의 oEmbed 를 동시에 받아 (1) title/channel 회수 (2) 채널 재랭킹.
                # 첫 결과를 무조건 채택하면 채널이 화면에 보여도 엉뚱한 영상이 잡힌다
                # (baseline recover 정확 3/8). channel_hint 가 있으면 author_name 이 맞는
                # 후보를 고르고, 맞는 게 없으면 빗나간 영상 대신 recovered=False 를 반환한다.
                oembeds = await asyncio.gather(*(self._oembed(hc, v) for v in ids))
                chosen = _choose_candidate(list(zip(ids, oembeds, strict=True)), channel_hint)
                if chosen is None:
                    return YoutubeRecoverOutput(recovered=False, candidates=ids)
                vid, o = chosen
                return YoutubeRecoverOutput(
                    recovered=True,
                    url=_watch_url(vid),
                    video_id=vid,
                    candidates=ids,
                    recovered_title=o.get("title"),
                    recovered_channel=o.get("author_name"),
                )
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("tool.youtube_recover.failed", query=query, error=str(exc))
            return YoutubeRecoverOutput(recovered=False, candidates=[])

    async def _oembed(self, hc: httpx.AsyncClient, vid: str) -> dict[str, Any] | None:
        """후보 1개의 oEmbed(title/author) 회수. 실패는 None(검증 불가 후보)."""
        try:
            ro = await hc.get(
                _OEMBED_URL, params={"format": "json", "url": _watch_url(vid)}, timeout=10
            )
            if ro.status_code != 200:
                return None
            data = ro.json()
            return data if isinstance(data, dict) else None
        except (httpx.HTTPError, ValueError):
            return None


def _watch_url(vid: str) -> str:
    return f"https://www.youtube.com/watch?v={vid}"


def _norm(s: str | None) -> str:
    return re.sub(r"[^0-9a-z가-힣]", "", (s or "").lower())


def _channel_match(author: str | None, hint: str) -> bool:
    """oEmbed author_name 이 화면 channel_hint 와 같은 채널인가(표기 차이 허용)."""
    a, h = _norm(author), _norm(hint)
    if not a or not h:
        return False
    if a in h or h in a:  # "너드킹" ⊂ "너드킹 NEP" 같은 부분 포함
        return True
    at = {t for t in re.sub(r"[^0-9a-z가-힣 ]", " ", (author or "").lower()).split() if len(t) > 1}
    ht = {t for t in re.sub(r"[^0-9a-z가-힣 ]", " ", (hint or "").lower()).split() if len(t) > 1}
    if not at or not ht:
        return False
    return len(at & ht) / len(at | ht) >= _CHANNEL_MATCH_MIN


def _choose_candidate(
    pairs: list[tuple[str, dict[str, Any] | None]], channel_hint: str | None
) -> tuple[str, dict[str, Any]] | None:
    """후보 (video_id, oEmbed) 들에서 채택할 1개. 없으면 None(→ recovered=False).

    channel_hint 가 있으면 author_name 이 맞는 첫 후보, 없으면(빗나간 영상 방지) None.
    channel_hint 가 없으면 oEmbed 검증된 첫 후보(기존 동작).
    """
    valid = [(vid, o) for vid, o in pairs if o]
    if not valid:
        return None
    if channel_hint:
        for vid, o in valid:
            if _channel_match(o.get("author_name"), channel_hint):
                return vid, o
        return None
    return valid[0]
