import ipaddress
import socket
import time
import zlib
from urllib.parse import urlparse

import httpx
from pydantic import BaseModel, HttpUrl

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage

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
        self._enforce_host_policy(str(payload.url), settings.web_fetch_blocked_hosts)

        # follow_redirects=False 로 직접 hop 마다 호스트 정책을 재검증한다.
        async with httpx.AsyncClient(timeout=settings.web_fetch_timeout_seconds) as client:
            current_url = str(payload.url)
            response: httpx.Response | None = None
            for _ in range(6):       # 1 + 최대 5 redirects
                try:
                    response = await client.get(current_url)
                except httpx.HTTPError as exc:
                    raise ToolExecutionError(self.name, f"HTTP error: {exc}", transient=True) from exc

                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise ToolExecutionError(self.name, "Redirect without Location header")
                    next_url = str(response.url.join(location))
                    self._enforce_host_policy(next_url, settings.web_fetch_blocked_hosts)
                    current_url = next_url
                    continue
                break
            else:
                raise ToolExecutionError(self.name, "Too many redirects")

            assert response is not None

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
                        raise ToolExecutionError(
                            self.name, f"Response too large (> {limit} bytes)"
                        )
            except (httpx.HTTPError, zlib.error) as exc:
                log.warning(
                    "tool.web_fetch.decode_failed",
                    url=current_url,
                    status_code=response.status_code,
                    content_type=response.headers.get("content-type"),
                    exception=str(exc),
                )
                raise ToolExecutionError(
                    self.name, f"HTTP decode error: {exc}", transient=True
                ) from exc

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

    def _enforce_host_policy(self, url: str, blocked: tuple[str, ...]) -> None:
        host = urlparse(url).hostname
        if not host:
            raise ToolExecutionError(self.name, "URL has no host")
        if host.lower() in blocked:
            raise ToolExecutionError(self.name, f"Blocked host: {host}")

        # 모든 A/AAAA 답변을 검증해 DNS rebinding 시 우회를 방지한다.
        candidates: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
        try:
            candidates.append(ipaddress.ip_address(host))
        except ValueError:
            try:
                infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
            except OSError as exc:
                raise ToolExecutionError(self.name, f"DNS resolution failed for {host}") from exc
            seen: set[str] = set()
            for info in infos:
                addr = str(info[4][0])
                if addr in seen:
                    continue
                seen.add(addr)
                try:
                    candidates.append(ipaddress.ip_address(addr))
                except ValueError:
                    continue

        for ip in candidates:
            if (
                ip.is_private
                or ip.is_loopback
                or ip.is_link_local
                or ip.is_multicast
                or ip.is_reserved
                or ip.is_unspecified
            ):
                raise ToolExecutionError(self.name, f"Blocked IP {ip} for host {host}")
