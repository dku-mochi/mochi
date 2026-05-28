from app.core.config import get_settings
from app.modules.search.domain.entities import SearchQuery, SearchResult
from app.modules.search.domain.ports import AnswerSynthesizer, Reranker, RetrievalIndex
from app.modules.search.infrastructure.rrf import reciprocal_rank_fusion


class HybridSearch:
    """RRF 융합 → (선택) Reranker → AnswerSynthesizer 합성. RAG 전체 파이프라인의 1급 유스케이스."""

    def __init__(
        self,
        index: RetrievalIndex,
        synthesizer: AnswerSynthesizer,
        reranker: Reranker | None = None,
    ):
        self._index = index
        self._synth = synthesizer
        self._reranker = reranker

    async def execute(self, query: SearchQuery) -> SearchResult:
        settings = get_settings()
        bm25 = await self._index.bm25(query)
        vec = await self._index.vector(query)
        merged = reciprocal_rank_fusion(bm25, vec, k=settings.rrf_k_constant)

        if self._reranker and settings.reranker_enabled:
            merged = await self._reranker.rerank(query.text, merged, top_n=settings.reranker_top_n)

        top = merged[: query.top_k]
        answer = await self._synth.synthesize(query.text, top, owner_id=query.owner_id)
        return SearchResult(answer=answer, citations=top, total_tokens=0)
