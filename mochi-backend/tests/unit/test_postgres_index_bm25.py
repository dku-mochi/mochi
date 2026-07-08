"""PostgresHybridIndex.bm25 — /search RAG 경로의 키워드 갈래 검증.

한국어 조사 회귀(2026-06-10)를 채팅 툴은 ILIKE 로 고쳤지만 이 경로는 tsvector ``@@`` 로
남아 같은 버그를 유지했었다. 공유 커널(app.shared.retrieval) 단일화로 두 경로가 같은
substring 매칭을 쓴다 — 그 계약을 여기서 못 박는다.
"""

from typing import Any
from uuid import uuid4

import pytest

from app.modules.search.domain.entities import SearchQuery
from app.modules.search.infrastructure.postgres_index import PostgresHybridIndex

pytestmark = pytest.mark.anyio


class _FakeResult:
    def __init__(self, rows: list[Any] | None = None):
        self._rows = rows or []

    def all(self) -> list[Any]:
        return self._rows


class _FakeSession:
    def __init__(self, captured: list[Any]):
        self._captured = captured

    async def execute(self, sql: Any) -> _FakeResult:
        self._captured.append(sql)
        return _FakeResult()


async def _embed_noop(_: str) -> list[float] | None:
    return None


async def _bm25_sql(query: SearchQuery) -> tuple[str, dict[str, Any]]:
    captured: list[Any] = []
    index = PostgresHybridIndex(_FakeSession(captured), query_embedding_provider=_embed_noop)  # type: ignore[arg-type]
    await index.bm25(query)
    sql = captured[0]
    return str(sql), dict(sql.compile().params)


async def test_bm25_matches_by_substring_not_token_equality() -> None:
    sql, params = await _bm25_sql(SearchQuery(text="민수 홍대", owner_id=uuid4()))
    # 조사 붙은 한국어를 0건 만들던 tsvector @@ 매칭은 없다 — 단어별 ILIKE substring.
    assert "@@ plainto_tsquery" not in sql
    assert "ILIKE :kw0" in sql and "ILIKE :kw1" in sql
    assert params["kw0"] == "%민수%" and params["kw1"] == "%홍대%"
    # 랭킹은 BM25 근사(ts_rank_cd) 유지 + owner 가드.
    assert "ts_rank_cd" in sql
    assert "owner_id = :owner_id" in sql


async def test_bm25_without_owner_returns_empty() -> None:
    captured: list[Any] = []
    index = PostgresHybridIndex(_FakeSession(captured), query_embedding_provider=_embed_noop)  # type: ignore[arg-type]
    assert await index.bm25(SearchQuery(text="민수", owner_id=None)) == []
    assert captured == []  # 쿼리 자체가 나가지 않는다


async def test_bm25_blank_query_returns_empty() -> None:
    captured: list[Any] = []
    index = PostgresHybridIndex(_FakeSession(captured), query_embedding_provider=_embed_noop)  # type: ignore[arg-type]
    assert await index.bm25(SearchQuery(text="   ", owner_id=uuid4())) == []
    assert captured == []  # 매칭할 단어가 없으면 0건 (기존 빈 tsquery 동작 보존)
