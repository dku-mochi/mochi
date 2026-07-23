import html
import json
import re
import time
import zlib
from typing import Literal
from urllib.parse import parse_qs, urlencode, urlparse

import httpx
from pydantic import BaseModel, HttpUrl

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage
from app.modules.agent.infrastructure.tools.safe_fetch import guarded_get

PlatformName = Literal["auto", "youtube", "x", "instagram"]
log = get_logger("agent.tool.platform_context")


class PlatformContextInput(BaseModel):
    url: HttpUrl
    platform: PlatformName = "auto"


class PlatformContextOutput(BaseModel):
    platform: str
    final_url: str
    status_code: int
    title: str | None = None
    author: str | None = None
    description: str | None = None
    duration_seconds: int | None = None
    thumbnail_url: str | None = None
    canonical_url: str | None = None
    source: str
    sufficient: bool
    confidence: float
    text: str


class PlatformContextTool(Tool[PlatformContextInput, PlatformContextOutput]):
    """YouTube/X/Instagram URL 을 저비용 구조 메타로 그라운딩한다.

    webFetch 보다 먼저 쓰는 좁은 adapter 이다. 네트워크 접근은 WebFetch 와 같은
    SSRF 가드/redirect 재검증/응답 크기 제한을 적용한다.
    """

    name = ToolName.PLATFORM_CONTEXT
    input_model = PlatformContextInput
    output_model = PlatformContextOutput

    ALLOWED_MIME_PREFIXES = (
        "text/html",
        "text/plain",
        "application/json",
        "application/xhtml+xml",
    )

    async def run(self, payload: PlatformContextInput) -> tuple[PlatformContextOutput, ToolUsage]:
        started = time.perf_counter()
        url = str(payload.url)
        platform = detect_platform(url) if payload.platform == "auto" else payload.platform

        if platform == "youtube":
            output = await self._youtube_context(url)
        elif platform == "x":
            output = await self._x_context(url)
        elif platform == "instagram":
            output = await self._instagram_context(url)
        else:
            raise ToolExecutionError(self.name, "Unsupported platform URL")

        usage = ToolUsage(latency_ms=int((time.perf_counter() - started) * 1000))
        return output, usage

    async def _youtube_context(self, url: str) -> PlatformContextOutput:
        # 공식 oEmbed 만 사용한다. 영상 페이지(watch) HTML 조회·파싱은 제거했다
        # (운영진 소명 2026-07-24). description/duration 은 제공하지 않는다.
        oembed_url = "https://www.youtube.com/oembed?" + urlencode({"url": url, "format": "json"})
        oembed_resp = await self._guarded_get_json(oembed_url)
        oembed = oembed_resp.json()

        page_url = _youtube_watch_url(url)  # 입력 URL 로부터 정규 watch URL 구성(네트워크 없음)
        title = _clean(oembed.get("title"))
        author = _clean(oembed.get("author_name"))
        thumbnail_url = _clean(oembed.get("thumbnail_url"))
        canonical_url = _clean(oembed.get("provider_url")) or page_url

        lines = [
            "platform: YouTube",
            f"title: {title or ''}",
            f"channel: {author or ''}",
        ]
        return PlatformContextOutput(
            platform="youtube",
            final_url=page_url or url,
            status_code=oembed_resp.status_code,
            title=title,
            author=author,
            description=None,
            duration_seconds=None,
            thumbnail_url=thumbnail_url,
            canonical_url=canonical_url,
            source="youtube_oembed",
            sufficient=bool(title and author),
            confidence=0.9 if title and author else 0.65,
            text="\n".join(lines),
        )

    async def _x_context(self, url: str) -> PlatformContextOutput:
        oembed_url = "https://publish.x.com/oembed?" + urlencode(
            {"url": url, "omit_script": "true", "dnt": "true"}
        )
        response = await self._guarded_get_json(oembed_url)
        data = response.json()
        title = _clean(data.get("title"))
        author = _clean(data.get("author_name"))
        canonical_url = _clean(data.get("url"))
        text = strip_html(_clean(data.get("html")) or "")
        description = text or title

        return PlatformContextOutput(
            platform="x",
            final_url=canonical_url or url,
            status_code=response.status_code,
            title=title,
            author=author,
            description=description,
            canonical_url=canonical_url,
            source="x_oembed",
            sufficient=bool(description or author),
            confidence=0.86 if description else 0.6,
            text="\n".join(
                [
                    "platform: X",
                    f"author: {author or ''}",
                    f"text: {description or ''}",
                ]
            ),
        )

    async def _instagram_context(self, url: str) -> PlatformContextOutput:
        settings = get_settings()
        if settings.instagram_oembed_access_token:
            endpoint = (
                f"https://graph.facebook.com/{settings.instagram_oembed_api_version}"
                "/instagram_oembed?"
                + urlencode(
                    {
                        "url": url,
                        "access_token": settings.instagram_oembed_access_token,
                    }
                )
            )
            response = await self._guarded_get_json(endpoint)
            data = response.json()
            title = _clean(data.get("title"))
            author = _clean(data.get("author_name"))
            text = strip_html(_clean(data.get("html")) or "")
            return PlatformContextOutput(
                platform="instagram",
                final_url=url,
                status_code=response.status_code,
                title=title,
                author=author,
                description=text or title,
                thumbnail_url=_clean(data.get("thumbnail_url")),
                canonical_url=url,
                source="instagram_oembed",
                sufficient=bool(title or text or author),
                confidence=0.76 if title or text else 0.55,
                text="\n".join(
                    [
                        "platform: Instagram",
                        f"author: {author or ''}",
                        f"context: {text or title or ''}",
                    ]
                ),
            )

        response = await self._guarded_get_text(url)
        meta = extract_meta_tags(response.text)
        title = meta.get("og:title") or meta.get("twitter:title") or meta.get("title")
        description = meta.get("og:description") or meta.get("description")
        thumbnail_url = meta.get("og:image") or meta.get("twitter:image")
        canonical_url = meta.get("og:url") or url
        return PlatformContextOutput(
            platform="instagram",
            final_url=str(response.url),
            status_code=response.status_code,
            title=title,
            description=description,
            thumbnail_url=thumbnail_url,
            canonical_url=canonical_url,
            source="instagram_og_fallback",
            sufficient=bool(title or description or thumbnail_url),
            confidence=0.58 if title or description else 0.35,
            text="\n".join(
                [
                    "platform: Instagram",
                    f"title: {title or ''}",
                    f"description: {description or ''}",
                    "note: Instagram image/post meaning often depends on the screenshot image itself.",
                ]
            ),
        )

    async def _guarded_get_json(self, url: str) -> httpx.Response:
        response = await self._guarded_get(url)
        mime = response.headers.get("content-type", "").split(";", 1)[0].lower()
        if "json" not in mime and not response.text.lstrip().startswith(("{", "[")):
            raise ToolExecutionError(self.name, f"Expected JSON, got {mime}")
        try:
            response.json()
        except json.JSONDecodeError as exc:
            log.warning(
                "tool.platform_context.json_decode_failed",
                url=url,
                status_code=response.status_code,
                content_type=response.headers.get("content-type"),
                body_length=len(response.content),
                exception=str(exc),
            )
            raise ToolExecutionError(self.name, f"Invalid JSON response: {exc}", transient=True) from exc
        return response

    async def _guarded_get_text(self, url: str) -> httpx.Response:
        return await self._guarded_get(url)

    async def _guarded_get(self, url: str) -> httpx.Response:
        settings = get_settings()
        async with httpx.AsyncClient(
            timeout=settings.web_fetch_timeout_seconds, follow_redirects=False
        ) as client:
            response, current_url = await guarded_get(
                client,
                url,
                blocked_hosts=settings.web_fetch_blocked_hosts,
                tool_name=self.name,
            )
            mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
            if mime and not mime.startswith(self.ALLOWED_MIME_PREFIXES):
                raise ToolExecutionError(self.name, f"Blocked MIME: {mime}")

            buffer = bytearray()
            limit = settings.web_fetch_max_bytes
            try:
                async for chunk in response.aiter_bytes():
                    buffer.extend(chunk)
                    if len(buffer) > limit:
                        raise ToolExecutionError(self.name, f"Response too large (> {limit} bytes)")
            except (httpx.HTTPError, zlib.error) as exc:
                log.warning(
                    "tool.platform_context.decode_failed",
                    url=current_url,
                    status_code=response.status_code,
                    content_type=response.headers.get("content-type"),
                    exception=str(exc),
                )
                raise ToolExecutionError(self.name, f"HTTP decode error: {exc}", transient=True) from exc
            headers = httpx.Headers(response.headers)
            headers.pop("content-encoding", None)
            headers.pop("content-length", None)
            try:
                return httpx.Response(
                    status_code=response.status_code,
                    headers=headers,
                    content=bytes(buffer),
                    request=response.request,
                    extensions=response.extensions,
                )
            except httpx.HTTPError as exc:
                log.warning(
                    "tool.platform_context.response_build_failed",
                    url=current_url,
                    status_code=response.status_code,
                    content_type=response.headers.get("content-type"),
                    exception=str(exc),
                )
                raise ToolExecutionError(self.name, f"HTTP decode error: {exc}", transient=True) from exc


def detect_platform(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    if host in {"youtu.be", "youtube.com", "www.youtube.com", "m.youtube.com"}:
        return "youtube"
    if host in {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}:
        return "x"
    if host in {"instagram.com", "www.instagram.com", "m.instagram.com"}:
        return "instagram"
    return "unknown"


def extract_meta_tags(text: str) -> dict[str, str]:
    meta: dict[str, str] = {}
    title_match = re.search(r"<title[^>]*>(.*?)</title>", text, re.IGNORECASE | re.DOTALL)
    if title_match:
        meta["title"] = _clean(strip_html(title_match.group(1))) or ""
    for match in re.finditer(r"<meta\s+([^>]+)>", text, re.IGNORECASE):
        attrs = _parse_attrs(match.group(1))
        key = attrs.get("property") or attrs.get("name")
        value = attrs.get("content")
        if key and value:
            meta[key.lower()] = _clean(value) or ""
    return {k: v for k, v in meta.items() if v}


def strip_html(text: str) -> str:
    no_tags = re.sub(r"<[^>]+>", " ", text)
    return _clean(html.unescape(no_tags)) or ""


def _youtube_watch_url(url: str) -> str | None:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host == "youtu.be":
        video_id = parsed.path.strip("/").split("/", 1)[0]
    else:
        video_id = parse_qs(parsed.query).get("v", [""])[0]
        if not video_id and parsed.path.startswith("/shorts/"):
            video_id = parsed.path.split("/")[2]
    if not video_id:
        return None
    return f"https://www.youtube.com/watch?v={video_id}"


def _parse_attrs(raw: str) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for match in re.finditer(r"""([:\w-]+)\s*=\s*(['"])(.*?)\2""", raw, re.DOTALL):
        attrs[match.group(1).lower()] = html.unescape(match.group(3))
    return attrs


def _clean(value: object | None) -> str | None:
    if value is None:
        return None
    cleaned = re.sub(r"\s+", " ", str(value)).strip()
    return html.unescape(cleaned) if cleaned else None
