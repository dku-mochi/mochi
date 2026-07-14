from typing import Protocol
from uuid import UUID

from app.modules.search.domain.entities import Citation, SearchQuery, SimilarItem


class RetrievalIndex(Protocol):
    """Hybrid 검색 구현체가 따라야 할 단일 outbound port."""

    async def bm25(self, query: SearchQuery) -> list[Citation]: ...
    async def vector(self, query: SearchQuery) -> list[Citation]: ...

    async def similar(
        self, *, owner_id: UUID, mochi_item_id: UUID, limit: int, min_score: float
    ) -> list[SimilarItem]:
        """대상 item 의 저장된 embedding 을 seed 로 한 cosine 이웃 top-k.

        query 텍스트가 아니라 기존 벡터가 입력이다(`/search` 와 다른 점). 자기 자신 제외 +
        owner-scoped + 임계값(`min_score`) 미달 컷 + 같은 출처 URL dedup. 대상에 embedding 이
        없으면(미색인·`VOYAGE_API_KEY` 미설정) 빈 리스트로 degrade."""
        ...


class Reranker(Protocol):
    async def rerank(self, query: str, candidates: list[Citation], top_n: int) -> list[Citation]: ...
