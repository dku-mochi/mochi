"""채팅 web 툴 (PR-4) — web_search(Tavily)·web_fetch(SSRF 가드 재사용 래퍼).

레지스트리 키 게이트는 test_chat_run.py 의 registry 테스트가 고정한다.
여기서는 두 툴의 결과 가공(truncation·텍스트화·compact)과 실패 경로
(가드 차단·HTTP 실패가 run 실패가 아니라 모델에 돌아가는 에러 payload)를 고정.
"""

from typing import Any
from uuid import uuid4

import httpx
import pytest
from pydantic import BaseModel, HttpUrl

from app.modules.agent.domain.tools import ToolExecutionError, ToolName, ToolUsage
from app.modules.conversations.infrastructure.tools import web_search as web_search_module
from app.modules.conversations.infrastructure.tools.web_fetch import (
    TEXT_CHARS,
    WebFetchChatTool,
)
from app.modules.conversations.infrastructure.tools.web_search import (
    CONTENT_CHARS,
    MAX_RESULTS,
    WebSearchTool,
)

_OWNER = uuid4()


# ---------- web_search ----------


class _FakeResponse:
    def __init__(self, status_code: int, body: dict[str, Any] | None = None):
        self.status_code = status_code
        self._body = body or {}

    def json(self) -> dict[str, Any]:
        return self._body


class _FakeAsyncClient:
    """httpx.AsyncClient 대역 — 마지막 요청을 기록하고 준비된 응답/예외를 돌려준다."""

    last_request: dict[str, Any] = {}
    response: _FakeResponse = _FakeResponse(200)
    error: Exception | None = None

    def __init__(self, **kwargs: Any):
        pass

    async def __aenter__(self) -> "_FakeAsyncClient":
        return self

    async def __aexit__(self, *args: Any) -> None:
        return None

    async def post(self, url: str, **kwargs: Any) -> _FakeResponse:
        type(self).last_request = {"url": url, **kwargs}
        if type(self).error is not None:
            raise type(self).error
        return type(self).response


@pytest.fixture
def fake_client(monkeypatch: pytest.MonkeyPatch) -> type[_FakeAsyncClient]:
    _FakeAsyncClient.last_request = {}
    _FakeAsyncClient.response = _FakeResponse(200, {"results": []})
    _FakeAsyncClient.error = None
    monkeypatch.setattr(web_search_module.httpx, "AsyncClient", _FakeAsyncClient)
    return _FakeAsyncClient


@pytest.mark.asyncio
async def test_web_search_truncates_results_and_builds_compact(fake_client: type[_FakeAsyncClient]) -> None:
    fake_client.response = _FakeResponse(
        200,
        {
            "results": [
                {"title": f"t{i}", "url": f"https://r{i}.example", "content": "x" * 1000}
                for i in range(MAX_RESULTS + 3)  # 초과분은 잘린다
            ]
        },
    )

    result = await WebSearchTool("tvly-test").run(owner_id=_OWNER, args={"query": "성수동 데이트"})

    assert fake_client.last_request["json"]["query"] == "성수동 데이트"
    assert fake_client.last_request["headers"]["Authorization"] == "Bearer tvly-test"
    assert result.payload["count"] == MAX_RESULTS
    assert all(len(r["content"]) == CONTENT_CHARS for r in result.payload["results"])
    # compact 는 상위 3건 title+url 만 — 과거 턴 히스토리 토큰 예산.
    assert result.compact == {
        "results": [{"title": f"t{i}", "url": f"https://r{i}.example"} for i in range(3)]
    }
    assert result.summary == f"웹에서 {MAX_RESULTS}개를 찾았어요"
    assert result.proposal is None


@pytest.mark.asyncio
async def test_web_search_empty_query_and_empty_results(fake_client: type[_FakeAsyncClient]) -> None:
    blank = await WebSearchTool("k").run(owner_id=_OWNER, args={"query": "  "})
    assert blank.payload == {"error": "query is required"}

    fake_client.response = _FakeResponse(200, {"results": []})
    empty = await WebSearchTool("k").run(owner_id=_OWNER, args={"query": "q"})
    assert empty.payload == {"results": [], "count": 0}
    assert empty.summary == "웹에서 결과를 못 찾았어요"


@pytest.mark.asyncio
async def test_web_search_http_failures_return_error_payload(fake_client: type[_FakeAsyncClient]) -> None:
    # 비-200 — 에러 payload 로 모델에 돌아간다 (run 실패 아님). 키는 어디에도 노출 금지.
    fake_client.response = _FakeResponse(429)
    throttled = await WebSearchTool("secret-key").run(owner_id=_OWNER, args={"query": "q"})
    assert throttled.payload == {"error": "web search failed: HTTP 429"}
    assert "secret-key" not in str(throttled)

    # 전송 계층 실패(타임아웃 등) — 동일하게 흡수.
    fake_client.error = httpx.ConnectTimeout("boom")
    down = await WebSearchTool("secret-key").run(owner_id=_OWNER, args={"query": "q"})
    assert down.payload == {"error": "web search request failed: ConnectTimeout"}
    assert "secret-key" not in str(down)


# ---------- web_fetch ----------


class _FetchInput(BaseModel):
    url: HttpUrl


class _FetchOutput(BaseModel):
    final_url: str
    status_code: int
    mime_type: str
    text: str


class _FakeFetchTool:
    """agent WebFetchTool 대역 — Tool 인터페이스 중 래퍼가 쓰는 부분만."""

    input_model = _FetchInput

    def __init__(self, output: _FetchOutput | None = None, error: Exception | None = None):
        self._output = output
        self._error = error
        self.received: _FetchInput | None = None

    async def run(self, payload: _FetchInput) -> tuple[_FetchOutput, ToolUsage]:
        self.received = payload
        if self._error is not None:
            raise self._error
        assert self._output is not None
        return self._output, ToolUsage()


@pytest.mark.asyncio
async def test_web_fetch_strips_html_and_truncates() -> None:
    html = (
        "<html><head><style>body{color:red}</style>"
        "<script>var hidden = 'leak';</script></head>"
        "<body><h1>제목</h1><p>본문 &amp; 내용</p>" + "<p>가</p>" * TEXT_CHARS + "</body></html>"
    )
    inner = _FakeFetchTool(
        output=_FetchOutput(
            final_url="https://example.com/a", status_code=200, mime_type="text/html", text=html
        )
    )

    result = await WebFetchChatTool(inner).run(
        owner_id=_OWNER, args={"url": "https://example.com/a"}
    )

    text = result.payload["text"]
    assert "<" not in text and "hidden" not in text and "color:red" not in text
    assert text.startswith("제목 본문 & 내용")
    assert len(text) == TEXT_CHARS and result.payload["truncated"] is True
    assert result.payload["url"] == "https://example.com/a"
    assert result.compact == {"url": "https://example.com/a"}


@pytest.mark.asyncio
async def test_web_fetch_keeps_non_html_raw() -> None:
    inner = _FakeFetchTool(
        output=_FetchOutput(
            final_url="https://api.example/j",
            status_code=200,
            mime_type="application/json",
            text='{"a": "<b>"}',
        )
    )
    result = await WebFetchChatTool(inner).run(owner_id=_OWNER, args={"url": "https://api.example/j"})
    assert result.payload["text"] == '{"a": "<b>"}'  # JSON 은 텍스트화하지 않는다
    assert result.payload["truncated"] is False


@pytest.mark.asyncio
async def test_web_fetch_guard_block_and_invalid_url_become_error_payload() -> None:
    # SSRF 가드 차단 — 사유가 모델에 돌아가 다른 출처로 우회하게 한다.
    blocked = _FakeFetchTool(
        error=ToolExecutionError(ToolName.WEB_FETCH, "Blocked IP 10.0.0.1 for host evil.test")
    )
    result = await WebFetchChatTool(blocked).run(owner_id=_OWNER, args={"url": "https://evil.test"})
    assert result.payload == {"error": "Blocked IP 10.0.0.1 for host evil.test"}
    assert result.summary == "페이지를 못 열었어요"

    # 비-URL 입력 — pydantic 검증 실패를 깨끗한 에러로.
    invalid = await WebFetchChatTool(_FakeFetchTool()).run(owner_id=_OWNER, args={"url": "넌 못 지나간다"})
    assert invalid.payload == {"error": "invalid url — must be an absolute http(s) URL"}
