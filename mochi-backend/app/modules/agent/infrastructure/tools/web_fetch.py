import time
import zlib

import httpx
from pydantic import BaseModel, HttpUrl

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage
from app.modules.agent.infrastructure.tools.safe_fetch import guarded_get

log = get_logger("agent.tool.web_fetch")


class WebFetchInput(BaseModel):
    url: HttpUrl


class WebFetchOutput(BaseModel):
    final_url: str
    status_code: int
    mime_type: str
    text: str


class WebFetchTool(Tool[WebFetchInput, WebFetchOutput]):
    """SSRF / 사이즈 / 타임아웃 가드를 적용한 외부 URL 본문 페치.

    가드:
    - 호스트 블록리스트 (메타데이터 IP, localhost ...)
    - 사설/링크로컬/루프백 IP 차단
    - 응답 사이즈 상한 (스트리밍 byte counter)
    - 타임아웃 (settings.web_fetch_timeout_seconds)
    - text/html, text/plain, application/json 만 허용
    - 매 redirect 마다 호스트/IP 재검증 (DNS rebinding 방지)
    """

    name = ToolName.WEB_FETCH
    input_model = WebFetchInput
    output_model = WebFetchOutput

    ALLOWED_MIME_PREFIXES = (
        "text/html",
        "text/plain",
        "application/json",
        "application/xhtml+xml",
    )

    async def run(self, payload: WebFetchInput) -> tuple[WebFetchOutput, ToolUsage]:
        settings = get_settings()
        started = time.perf_counter()

        # follow_redirects=False 로 hop 마다 SSRF 검증 + 검증한 IP 로 직접 연결(TOCTOU 차단).
        async with httpx.AsyncClient(
            timeout=settings.web_fetch_timeout_seconds, follow_redirects=False
        ) as client:
            response, current_url = await guarded_get(
                client,
                str(payload.url),
                blocked_hosts=settings.web_fetch_blocked_hosts,
                tool_name=self.name,
            )

            mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
            if not mime.startswith(self.ALLOWED_MIME_PREFIXES):
                raise ToolExecutionError(self.name, f"Blocked MIME: {mime}")

            # 사이즈 상한을 만족하는 만큼만 스트리밍으로 읽어 메모리/대역 보호.
            buffer = bytearray()
            limit = settings.web_fetch_max_bytes
            try:
                async for chunk in response.aiter_bytes():
                    buffer.extend(chunk)
                    if len(buffer) > limit:
                        raise ToolExecutionError(self.name, f"Response too large (> {limit} bytes)")
            except (httpx.HTTPError, zlib.error) as exc:
                log.warning(
                    "tool.web_fetch.decode_failed",
                    url=current_url,
                    status_code=response.status_code,
                    content_type=response.headers.get("content-type"),
                    exception=str(exc),
                )
                raise ToolExecutionError(self.name, f"HTTP decode error: {exc}", transient=True) from exc

        text = buffer.decode("utf-8", errors="replace")
        usage = ToolUsage(
            tokens_in=0,
            tokens_out=0,
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
        return (
            WebFetchOutput(
                final_url=current_url,
                status_code=response.status_code,
                mime_type=mime,
                text=text,
            ),
            usage,
        )
