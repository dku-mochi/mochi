"""VoyageClient 단위 테스트 — httpx.MockTransport 로 HTTP 계약을 고정한다.

고정하는 계약: input_type(doc/query) 구분, output_dimension, 배치 분할, 차원 검증,
rerank 응답 파싱(index 보존), 일시 오류(429/5xx) 재시도 + 영구 오류(4xx) 즉시 실패.
"""

import json
from typing import Any

import httpx
import pytest

from app.shared.voyage import VoyageClient, VoyageError, build_embedding_text

pytestmark = pytest.mark.anyio

DIM = 4


def _client(handler: Any, **kwargs: Any) -> VoyageClient:
    return VoyageClient(
        "test-key",
        embedding_model="voyage-4-large",
        embedding_dim=DIM,
        rerank_model="rerank-2.5",
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


def _embedding_response(count: int, dim: int = DIM) -> httpx.Response:
    return httpx.Response(200, json={"data": [{"embedding": [0.1] * dim} for _ in range(count)]})


def test_build_embedding_text_joins_summary_and_labels() -> None:
    # rag-rerank-eval 고정 조건: doc text = summary + labels. 빈 값·None 은 건너뛴다.
    assert build_embedding_text("요약", ["라벨1", None, "", "라벨2"]) == "요약 라벨1 라벨2"
    assert build_embedding_text(None, []) == ""
    assert build_embedding_text("", [None]) == ""


async def test_embed_query_sends_query_input_type_and_dimension() -> None:
    captured: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return _embedding_response(1)

    vector = await _client(handler).embed_query("보라카이 숙소")
    assert vector == [0.1] * DIM
    assert captured[0]["input_type"] == "query"
    assert captured[0]["output_dimension"] == DIM
    assert captured[0]["model"] == "voyage-4-large"


async def test_embed_documents_batches_over_api_limit() -> None:
    batch_sizes: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        assert body["input_type"] == "document"
        batch_sizes.append(len(body["input"]))
        return _embedding_response(len(body["input"]))

    vectors = await _client(handler).embed_documents([f"doc{i}" for i in range(130)])
    assert len(vectors) == 130
    assert batch_sizes == [128, 2]


async def test_embed_rejects_dimension_mismatch() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _embedding_response(1, dim=DIM + 1)

    with pytest.raises(VoyageError, match="dimension mismatch"):
        await _client(handler).embed_query("q")


async def test_rerank_parses_results_preserving_input_index() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        assert body["model"] == "rerank-2.5"
        assert body["top_k"] == 2
        return httpx.Response(
            200,
            json={
                "data": [
                    {"index": 2, "relevance_score": 0.9},
                    {"index": 0, "relevance_score": 0.4},
                ]
            },
        )

    ranked = await _client(handler).rerank(query="q", documents=["a", "b", "c"], top_k=2)
    assert [(r.index, r.relevance_score) for r in ranked] == [(2, 0.9), (0, 0.4)]


async def test_rerank_empty_documents_short_circuits() -> None:
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover — 호출되면 안 된다
        raise AssertionError("no HTTP call expected")

    assert await _client(handler).rerank(query="q", documents=[], top_k=5) == []


async def test_transient_status_is_retried_then_succeeds() -> None:
    statuses = [429, 200]

    def handler(request: httpx.Request) -> httpx.Response:
        status = statuses.pop(0)
        if status != 200:
            return httpx.Response(status, json={})
        return _embedding_response(1)

    vector = await _client(handler).embed_query("q")
    assert vector == [0.1] * DIM
    assert statuses == []  # 두 번째 시도까지 소비


async def test_permanent_error_fails_without_retry() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(401, json={})

    with pytest.raises(VoyageError, match="HTTP 401"):
        await _client(handler).embed_query("q")
    assert calls == 1


async def test_transport_failure_exhaustion_raises_voyage_error() -> None:
    # 리뷰 P1: DNS 장애·연결 거부·타임아웃이 원형(httpx.*) 그대로 새면 호출부의
    # `except VoyageError` degrade 가 뚫린다 — 소진 후에도 반드시 VoyageError 로 래핑.
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        raise httpx.ConnectError("connection refused")

    with pytest.raises(VoyageError, match="ConnectError"):
        await _client(handler).embed_query("q")
    assert calls == 2  # 인터랙티브 예산 — 2회 시도 후 포기


async def test_malformed_json_raises_voyage_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>not json</html>")

    with pytest.raises(VoyageError, match="malformed JSON"):
        await _client(handler).embed_query("q")
