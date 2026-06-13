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

import re
import time

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


class YoutubeRecoverInput(BaseModel):
    query: str  # 화면에서 읽은 채널 + 제목 키워드 (원본 영상 검색어)


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
        out = await self._recover(payload.query)
        usage = ToolUsage(latency_ms=int((time.perf_counter() - started) * 1000))
        return out, usage

    async def _recover(self, query: str) -> YoutubeRecoverOutput:
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
                if not ids:
                    return YoutubeRecoverOutput(recovered=False, candidates=[])
                vid = ids[0]
                url = f"https://www.youtube.com/watch?v={vid}"
                # oEmbed 로 복원 검증 — title/channel 회수.
                ro = await hc.get(
                    _OEMBED_URL, params={"format": "json", "url": url}, timeout=10
                )
                if ro.status_code != 200:
                    return YoutubeRecoverOutput(
                        recovered=False, url=url, video_id=vid, candidates=ids[:5]
                    )
                o = ro.json()
                return YoutubeRecoverOutput(
                    recovered=True,
                    url=url,
                    video_id=vid,
                    candidates=ids[:5],
                    recovered_title=o.get("title"),
                    recovered_channel=o.get("author_name"),
                )
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("tool.youtube_recover.failed", query=query, error=str(exc))
            return YoutubeRecoverOutput(recovered=False, candidates=[])
