"""recoverYoutubeUrl — 이미지 단서(채널+제목)로 원본 유튜브 watch URL 을 회수하는 tool.

출처앱이 YouTube 이고 화면이 영상/쇼츠/댓글일 때, 메인 에이전트가 이미지에서 읽은
제목(query)+채널(channel_hint)을 넘기면 이 tool 이 원본 watch URL 을 찾아 검증한다.
"영상 속 추천 리스트"는 텍스트 검색으로 못 찾는다 → 답은 원본 영상 URL 회수다.

**공식 YouTube Data API v3 만 사용한다.** 검색결과·영상·채널 페이지 HTML 을 조회·파싱하는
경로(무키 검색)는 전면 제거했다(운영진 소명 2026-07-24). API 키가 없으면 아무 요청도 하지
않고 ``recovered=False`` 를 반환한다.

3단계 (앞 단계가 못 찾으면 다음으로):
  1. 채널 식별(forHandle → search type=channel) → **uploads playlist 직접 조회**
     (인덱스 무관, 1 unit): 최신 N개에서 제목 매칭.
  2. **search.list**(100 unit): 채널 한정(channelId) 또는 전역 → 채널/제목 매칭.
  3. **채널 주소 fallback**: 영상을 끝내 못 찾으면 채널 URL 이라도 반환(사용자가 채널서 찾게).

LLM 호출 없음 → ToolUsage 는 latency 만.
"""

import re
import time
from typing import Any

import httpx
from pydantic import BaseModel

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolName, ToolUsage

log = get_logger("agent.tool.youtube_recover")

_YT_API = "https://www.googleapis.com/youtube/v3"
_MAX_QUERY_LEN = 120  # 검색어 길이 상한 — 외부 검색 전 bound
_UPLOADS_SCAN = 50  # uploads playlist 에서 제목 매칭할 최신 영상 수
_CHANNEL_MATCH_MIN = 0.34  # 채널명 토큰 자카드 임계
_TITLE_MATCH_MIN = 0.5  # 채널 표기차 fallback — query 토큰의 절반 이상이 후보 제목에 등장


class YoutubeRecoverInput(BaseModel):
    query: str  # 화면에서 읽은 영상 제목 키워드 (원본 영상 검색어)
    channel_hint: str | None = None  # 화면에서 읽은 채널명(@핸들 포함) — 후보 재랭킹·채널 식별 신호


class YoutubeRecoverOutput(BaseModel):
    recovered: bool
    url: str | None = None
    video_id: str | None = None
    candidates: list[str] = []
    recovered_title: str | None = None
    recovered_channel: str | None = None
    channel_url: str | None = None  # 영상 못 찾을 때 fallback — 채널로라도 보내준다
    source: str | None = None  # "api_uploads" | "api_search" | "channel_only"


class RecoverYoutubeUrlTool(Tool[YoutubeRecoverInput, YoutubeRecoverOutput]):
    """이미지 단서로 원본 유튜브 watch URL 을 회수(공식 YouTube Data API v3 전용).

    실패는 예외가 아니라 ``recovered=False`` 로 반환(채널 주소가 있으면 채워서)해 모델이
    "복원 안 됨/채널만 있음"을 보고 진행하게 한다(되먹임).
    """

    name = ToolName.RECOVER_YOUTUBE_URL
    input_model = YoutubeRecoverInput
    output_model = YoutubeRecoverOutput

    async def run(self, payload: YoutubeRecoverInput) -> tuple[YoutubeRecoverOutput, ToolUsage]:
        started = time.perf_counter()
        out = await self._recover(payload.query[:_MAX_QUERY_LEN], payload.channel_hint)
        usage = ToolUsage(latency_ms=int((time.perf_counter() - started) * 1000))
        return out, usage

    async def _recover(self, query: str, channel_hint: str | None) -> YoutubeRecoverOutput:
        key = get_settings().youtube_api_key
        if not key:  # 공식 API 전용 — 키 없으면 아무 요청도 하지 않는다.
            return YoutubeRecoverOutput(recovered=False)
        async with httpx.AsyncClient(timeout=15) as hc:
            # 1) YouTube Data API: 채널 식별 → uploads 직접조회 → search.
            out = await self._search_api(hc, query, channel_hint, key)
            if out is not None:
                return out
            # 2) 영상 못 찾음 → 채널 주소라도(사용자가 채널서 찾게).
            channel_url = await _resolve_channel_url(hc, channel_hint, key)
            return YoutubeRecoverOutput(
                recovered=False,
                channel_url=channel_url,
                source="channel_only" if channel_url else None,
            )

    async def _search_api(
        self, hc: httpx.AsyncClient, query: str, channel_hint: str | None, key: str
    ) -> YoutubeRecoverOutput | None:
        """YouTube Data API — 채널 식별 → uploads(인덱스 무관) → search.list."""
        cid, uploads, ctitle, _ = await _api_resolve_channel(hc, channel_hint, key)
        # uploads 직접 조회 — 막 올라온 영상도 인덱스 무관하게 잡힌다(1 unit).
        if uploads:
            hit = await _api_match_uploads(hc, uploads, query, key)
            if hit:
                vid, title = hit
                return YoutubeRecoverOutput(
                    recovered=True,
                    url=_watch_url(vid),
                    video_id=vid,
                    recovered_title=title,
                    recovered_channel=ctitle,
                    source="api_uploads",
                )
        # search.list 폴백(100 unit) — 채널 한정(cid) 또는 전역.
        hit2 = await _api_search(hc, query, channel_hint, cid, key)
        if hit2:
            vid, title, ch = hit2
            return YoutubeRecoverOutput(
                recovered=True,
                url=_watch_url(vid),
                video_id=vid,
                recovered_title=title,
                recovered_channel=ch,
                source="api_search",
            )
        return None


# ── YouTube Data API 헬퍼 ─────────────────────────────────────────────────────
async def _api_get(hc: httpx.AsyncClient, key: str, path: str, params: dict[str, Any]) -> dict[str, Any]:
    r = await hc.get(f"{_YT_API}/{path}", params={**params, "key": key}, timeout=15)
    r.raise_for_status()
    data = r.json()
    return data if isinstance(data, dict) else {}


def _channel_tuple(item: dict[str, Any]) -> tuple[str, str, str, str]:
    """channels.list item → (channelId, uploads_playlist, title, channel_url)."""
    cid = item["id"]
    uploads = item["contentDetails"]["relatedPlaylists"]["uploads"]
    snippet = item.get("snippet", {})
    title = snippet.get("title", "")
    custom = snippet.get("customUrl")  # "@handle" 형태(있으면)
    url = f"https://www.youtube.com/{custom}" if custom else f"https://www.youtube.com/channel/{cid}"
    return cid, uploads, title, url


async def _api_resolve_channel(
    hc: httpx.AsyncClient, hint: str | None, key: str
) -> tuple[str | None, str | None, str | None, str | None]:
    """channel_hint → (channelId, uploads, title, channel_url). 핸들 우선, 채널명 search 폴백."""
    if not hint:
        return None, None, None, None
    handle = hint.strip().lstrip("@")
    # 1) forHandle — @핸들 형태(공백 없음)
    if handle and " " not in handle:
        try:
            d = await _api_get(hc, key, "channels", {"part": "contentDetails,snippet", "forHandle": handle})
            items = d.get("items") or []
            if items:
                return _channel_tuple(items[0])
        except (httpx.HTTPError, ValueError, KeyError):
            pass
    # 2) search type=channel — 채널명(공백 포함 등)
    try:
        d = await _api_get(
            hc, key, "search", {"part": "snippet", "q": hint, "type": "channel", "maxResults": 1}
        )
        items = d.get("items") or []
        if items:
            ccid = items[0]["snippet"]["channelId"]
            d2 = await _api_get(hc, key, "channels", {"part": "contentDetails,snippet", "id": ccid})
            it2 = (d2.get("items") or [None])[0]
            if it2:
                return _channel_tuple(it2)
    except (httpx.HTTPError, ValueError, KeyError):
        pass
    return None, None, None, None


async def _api_match_uploads(
    hc: httpx.AsyncClient, uploads: str, query: str, key: str
) -> tuple[str, str] | None:
    """uploads playlist 최신 N개에서 query 제목 매칭 → (video_id, title). 인덱스 무관(1 unit)."""
    try:
        d = await _api_get(
            hc, key, "playlistItems", {"part": "snippet", "playlistId": uploads, "maxResults": _UPLOADS_SCAN}
        )
    except (httpx.HTTPError, ValueError):
        return None
    for it in d.get("items", []):
        sn = it.get("snippet", {})
        title = sn.get("title", "")
        if _title_match(title, query):
            vid = sn.get("resourceId", {}).get("videoId")
            if vid:
                return vid, title
    return None


async def _api_search(
    hc: httpx.AsyncClient, query: str, channel_hint: str | None, cid: str | None, key: str
) -> tuple[str, str, str] | None:
    """search.list q(+channelId) → 채널/제목 매칭 첫 영상 → (vid, title, channel). 100 unit."""
    params: dict[str, Any] = {"part": "snippet", "q": query, "type": "video", "maxResults": 5}
    if cid:
        params["channelId"] = cid
    try:
        d = await _api_get(hc, key, "search", params)
    except (httpx.HTTPError, ValueError):
        return None
    for it in d.get("items", []):
        sn = it.get("snippet", {})
        title = sn.get("title", "")
        ch = sn.get("channelTitle", "")
        # channelId 한정이면 이미 채널 일치; 아니면 채널 또는 제목 매칭으로 게이트.
        if cid or (channel_hint and _channel_match(ch, channel_hint)) or _title_match(title, query):
            vid = it.get("id", {}).get("videoId")
            if vid:
                return vid, title, ch
    return None


async def _resolve_channel_url(hc: httpx.AsyncClient, hint: str | None, key: str) -> str | None:
    """영상 못 찾을 때 채널 주소라도 — 공식 API 로 채널 식별(HTML fallback 없음)."""
    if not hint:
        return None
    _, _, _, url = await _api_resolve_channel(hc, hint, key)
    return url


# ── 매칭 헬퍼 ─────────────────────────────────────────────────────────────────
def _watch_url(vid: str) -> str:
    return f"https://www.youtube.com/watch?v={vid}"


def _norm(s: str | None) -> str:
    return re.sub(r"[^0-9a-z가-힣]", "", (s or "").lower())


def _word_tokens(s: str | None) -> set[str]:
    return {t for t in re.sub(r"[^0-9a-z가-힣 ]", " ", (s or "").lower()).split() if len(t) > 1}


def _channel_match(author: str | None, hint: str) -> bool:
    """snippet channelTitle 이 화면 channel_hint 와 같은 채널인가(표기 차이 허용)."""
    a, h = _norm(author), _norm(hint)
    if not a or not h:
        return False
    if a in h or h in a:  # "너드킹" ⊂ "너드킹 NEP" 같은 부분 포함
        return True
    at, ht = _word_tokens(author), _word_tokens(hint)
    if not at or not ht:
        return False
    return len(at & ht) / len(at | ht) >= _CHANNEL_MATCH_MIN


def _title_match(title: str | None, query: str) -> bool:
    """후보 제목이 검색 query 와 강하게 겹치는가 — query 토큰의 절반 이상이 제목에 등장.

    채널 표기차(한↔영: 따라cook/따라쿡, codingapple/코딩애플)로 채널 매칭이 빗나갈 때의
    fallback. 제목까지 안 겹치면(채널·제목 둘 다 다름 = 진짜 빗나감) 채택하지 않는다.
    """
    tt, qt = _word_tokens(title), _word_tokens(query)
    if not tt or not qt:
        return False
    return len(qt & tt) / len(qt) >= _TITLE_MATCH_MIN
