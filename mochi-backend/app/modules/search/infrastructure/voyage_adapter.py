"""search 모듈의 Voyage port 구현 — 쿼리 임베딩 provider + ``rerank-2.5`` Reranker.

검색은 외부 API 장애로 죽으면 안 된다(키워드라도 돌려준다):
- 쿼리 임베딩 실패 → ``None`` 반환 → vector 후보 생략, BM25 단독 degrade
- 리랭크 실패 → RRF 순서 그대로 상위 N 반환

모델 선택 근거는 ``lab/active/rag-rerank-eval``(2026-06-12) — rerank-2.5 가
vector 단독 대비 R@1 0.15→0.43, MRR 0.56→0.88.
"""

from collections.abc import Awaitable, Callable
from dataclasses import replace

from app.core.logging import get_logger
from app.modules.search.domain.entities import Citation
from app.modules.search.domain.ports import Reranker
from app.shared.voyage import VoyageClient, VoyageError

log = get_logger("search.voyage")


def make_query_embedder(
    client: VoyageClient | None,
) -> Callable[[str], Awaitable[list[float] | None]]:
    """``PostgresHybridIndex`` 의 query_embedding_provider — 실패를 ``None`` 으로 수렴."""

    async def embed(query_text: str) -> list[float] | None:
        if client is None:
            return None
        try:
            return await client.embed_query(query_text)
        except VoyageError as exc:
            log.warning("search.query_embed_failed", exception=str(exc))
            return None

    return embed


class VoyageReranker(Reranker):
    """rerank-2.5 로 후보를 재정렬한다. score 는 reranker relevance 로 교체된다."""

    def __init__(self, client: VoyageClient):
        self._client = client

    async def rerank(self, query: str, candidates: list[Citation], top_n: int) -> list[Citation]:
        if not candidates:
            return []
        try:
            ranked = await self._client.rerank(
                query=query, documents=[c.snippet for c in candidates], top_k=top_n
            )
        except VoyageError as exc:
            log.warning("search.rerank_failed", exception=str(exc))
            return candidates[:top_n]
        return [
            replace(candidates[r.index], score=r.relevance_score)
            for r in ranked
            if 0 <= r.index < len(candidates)
        ]
