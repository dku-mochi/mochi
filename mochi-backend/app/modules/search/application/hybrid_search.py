from app.core.config import get_settings
from app.modules.search.domain.entities import SearchQuery, SearchResult
from app.modules.search.domain.ports import Reranker, RetrievalIndex
from app.modules.search.infrastructure.rrf import reciprocal_rank_fusion


class HybridSearch:
    """RRF 융합 → (선택) Reranker. 하이브리드 retrieval 파이프라인의 1급 유스케이스."""

    def __init__(
        self,
        index: RetrievalIndex,
        reranker: Reranker | None = None,
    ):
        self._index = index
        self._reranker = reranker

    async def execute(self, query: SearchQuery) -> SearchResult:
        settings = get_settings()
        bm25 = await self._index.bm25(query)
        vec = await self._index.vector(query)
        merged = reciprocal_rank_fusion(bm25, vec, k=settings.rrf_k_constant)

        if self._reranker and settings.reranker_enabled:
            merged = await self._reranker.rerank(query.text, merged, top_n=settings.reranker_top_n)

        top = merged[: query.top_k]
        return SearchResult(citations=top, total_tokens=0)
