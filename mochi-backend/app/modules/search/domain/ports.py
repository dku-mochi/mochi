from typing import Protocol
from uuid import UUID

from app.modules.search.domain.entities import Citation, SearchQuery


class RetrievalIndex(Protocol):
    """Hybrid 검색 구현체가 따라야 할 단일 outbound port."""

    async def bm25(self, query: SearchQuery) -> list[Citation]: ...
    async def vector(self, query: SearchQuery) -> list[Citation]: ...


class Reranker(Protocol):
    async def rerank(self, query: str, candidates: list[Citation], top_n: int) -> list[Citation]: ...


class AnswerSynthesizer(Protocol):
    async def synthesize(self, query: str, citations: list[Citation], owner_id: UUID | None) -> str: ...
