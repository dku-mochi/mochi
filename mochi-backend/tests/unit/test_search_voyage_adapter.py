"""search 모듈 Voyage 어댑터 — degrade 계약을 고정한다.

검색은 외부 API 장애로 죽으면 안 된다: 쿼리 임베딩 실패 → None(vector 생략, BM25 단독),
리랭크 실패 → RRF 순서 그대로 truncate.
"""

from uuid import uuid4

import pytest

from app.modules.search.domain.entities import Citation
from app.modules.search.infrastructure.postgres_index import vector_literal
from app.modules.search.infrastructure.voyage_adapter import VoyageReranker, make_query_embedder
from app.shared.voyage import RerankedDocument, VoyageError

pytestmark = pytest.mark.anyio


class _FakeVoyage:
    def __init__(self, *, fail: bool = False, ranked: list[RerankedDocument] | None = None):
        self._fail = fail
        self._ranked = ranked or []
        self.rerank_calls: list[dict] = []

    async def embed_query(self, text: str) -> list[float]:
        if self._fail:
            raise VoyageError("down")
        return [0.5, 0.5]

    async def rerank(self, *, query: str, documents: list[str], top_k: int) -> list[RerankedDocument]:
        if self._fail:
            raise VoyageError("down")
        self.rerank_calls.append({"query": query, "documents": documents, "top_k": top_k})
        return self._ranked


def _citations(n: int) -> list[Citation]:
    return [Citation(mochi_item_id=uuid4(), snippet=f"snippet-{i}", score=float(n - i)) for i in range(n)]


async def test_embedder_returns_none_without_client() -> None:
    assert await make_query_embedder(None)("q") is None


async def test_embedder_swallows_voyage_error_as_none() -> None:
    assert await make_query_embedder(_FakeVoyage(fail=True))("q") is None  # type: ignore[arg-type]


async def test_embedder_passes_through_vector() -> None:
    assert await make_query_embedder(_FakeVoyage())("q") == [0.5, 0.5]  # type: ignore[arg-type]


async def test_reranker_reorders_and_replaces_score() -> None:
    candidates = _citations(3)
    fake = _FakeVoyage(ranked=[
        RerankedDocument(index=2, relevance_score=0.9),
        RerankedDocument(index=0, relevance_score=0.3),
    ])
    out = await VoyageReranker(fake).rerank("q", candidates, top_n=2)  # type: ignore[arg-type]
    assert [c.mochi_item_id for c in out] == [candidates[2].mochi_item_id, candidates[0].mochi_item_id]
    assert [c.score for c in out] == [0.9, 0.3]
    # rerank 문서는 사용자에게 보이는 snippet 그대로.
    assert fake.rerank_calls[0]["documents"] == ["snippet-0", "snippet-1", "snippet-2"]


async def test_reranker_falls_back_to_input_order_on_failure() -> None:
    candidates = _citations(5)
    out = await VoyageReranker(_FakeVoyage(fail=True)).rerank("q", candidates, top_n=3)  # type: ignore[arg-type]
    assert out == candidates[:3]


async def test_reranker_drops_out_of_range_indices() -> None:
    candidates = _citations(2)
    fake = _FakeVoyage(ranked=[RerankedDocument(index=9, relevance_score=0.9)])
    assert await VoyageReranker(fake).rerank("q", candidates, top_n=2) == []  # type: ignore[arg-type]


def test_vector_literal_is_pgvector_text_form() -> None:
    assert vector_literal([0.1, -0.2, 1.0]) == "[0.1,-0.2,1.0]"
