from app.modules.agent.infrastructure.tools.platform_context import (
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
