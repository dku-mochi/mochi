import zlib

import pytest

from app.modules.agent.domain.tools import ToolExecutionError
from app.modules.agent.infrastructure.tools.platform_context import (
    PlatformContextTool,
    detect_platform,
    extract_meta_tags,
    parse_youtube_player_response,
    strip_html,
)


def test_detect_platform_supported_hosts():
    assert detect_platform("https://youtu.be/abc") == "youtube"
    assert detect_platform("https://www.youtube.com/watch?v=abc") == "youtube"
    assert detect_platform("https://x.com/user/status/1") == "x"
    assert detect_platform("https://twitter.com/user/status/1") == "x"
    assert detect_platform("https://www.instagram.com/p/abc/") == "instagram"
    assert detect_platform("https://example.com") == "unknown"


def test_parse_youtube_player_response_nested_json():
    html = """
    <script>
    var ytInitialPlayerResponse = {"videoDetails":{"title":"T","lengthSeconds":"123",
    "shortDescription":"hello { nested-looking } text"}};
    </script>
    """
    parsed = parse_youtube_player_response(html)
    assert parsed is not None
    assert parsed["videoDetails"]["lengthSeconds"] == "123"
    assert parsed["videoDetails"]["shortDescription"] == "hello { nested-looking } text"


def test_extract_meta_tags_and_strip_html():
    html = """
    <html><head>
      <title> Instagram </title>
      <meta property="og:title" content="Post title &amp; topic">
      <meta name="description" content="A short caption">
      <meta property="og:image" content="https://cdn.example/image.jpg">
    </head></html>
    """
    meta = extract_meta_tags(html)
    assert meta["title"] == "Instagram"
    assert meta["og:title"] == "Post title & topic"
    assert meta["description"] == "A short caption"
    assert meta["og:image"] == "https://cdn.example/image.jpg"
    assert strip_html("<p>Hello <b>world</b>&amp; friends</p>") == "Hello world & friends"


@pytest.mark.asyncio
async def test_guarded_get_wraps_decode_errors(monkeypatch):
    class BrokenResponse:
        status_code = 200
        headers = {"content-type": "application/json"}
        request = None
        extensions = {}

        @property
        def is_redirect(self):
            return False

        async def aiter_bytes(self):
            raise zlib.error("incorrect header check")
            yield b""  # pragma: no cover

    class FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url):
            return BrokenResponse()

    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.platform_context.httpx.AsyncClient",
        FakeClient,
    )

    with pytest.raises(ToolExecutionError, match="HTTP decode error"):
        await PlatformContextTool()._guarded_get("https://www.youtube.com/watch?v=abc")


@pytest.mark.asyncio
async def test_guarded_get_does_not_double_decode_buffer(monkeypatch):
    class EncodedHeaderResponse:
        status_code = 404
        headers = {
            "content-type": "application/json",
            "content-encoding": "gzip",
            "content-length": "20",
        }
        request = None
        extensions = {}

        @property
        def is_redirect(self):
            return False

        async def aiter_bytes(self):
            yield b'{"error":"not found"}'

    class FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url):
            return EncodedHeaderResponse()

    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.platform_context.httpx.AsyncClient",
        FakeClient,
    )

    response = await PlatformContextTool()._guarded_get(
        "https://www.youtube.com/watch?v=abc"
    )

    assert response.status_code == 404
    assert response.headers.get("content-encoding") is None
    assert response.json() == {"error": "not found"}


@pytest.mark.asyncio
async def test_guarded_get_json_wraps_invalid_json(monkeypatch):
    class EmptyJsonResponse:
        status_code = 400
        headers = {"content-type": "application/json"}
        request = None
        extensions = {}

        @property
        def is_redirect(self):
            return False

        async def aiter_bytes(self):
            yield b""

    class FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url):
            return EmptyJsonResponse()

    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.platform_context.httpx.AsyncClient",
        FakeClient,
    )

    with pytest.raises(ToolExecutionError, match="Invalid JSON response"):
        await PlatformContextTool()._guarded_get_json(
            "https://www.youtube.com/oembed?url=bad"
        )
