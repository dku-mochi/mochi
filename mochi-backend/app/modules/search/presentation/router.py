from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.core.deps import DBSession, get_voyage_client
from app.core.security import CurrentUser
from app.modules.search.application.hybrid_search import HybridSearch
from app.modules.search.domain.entities import Citation, SearchQuery, SearchScope
from app.modules.search.domain.ports import AnswerSynthesizer
from app.modules.search.infrastructure.postgres_index import PostgresHybridIndex
from app.modules.search.infrastructure.voyage_adapter import VoyageReranker, make_query_embedder

router = APIRouter(prefix="/search", tags=["search"])


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=512)
    scope: SearchScope = SearchScope.ALL


class CitationDTO(BaseModel):
    mochi_item_id: UUID = Field(alias="mochiItemId")
    snippet: str
    score: float

    model_config = {"populate_by_name": True}


class SearchResponse(BaseModel):
    answer: str
    citations: list[CitationDTO]
    total_tokens: int = Field(default=0, alias="totalTokens")
    agent_run_id: UUID | None = Field(default=None, alias="agentRunId")

    model_config = {"populate_by_name": True}


class _ExtractiveSynthesizer(AnswerSynthesizer):
    """Synthesizer가 wire 되기 전까지 사용하는 추출 fallback.

    상위 N개 citation 의 snippet을 그대로 이어 붙여 답을 만든다.
    Gemini synthesizer가 wire 되면 ``app/modules/agent`` 어댑터로 교체된다.
    """

    async def synthesize(self, query: str, citations: list[Citation], owner_id: UUID | None) -> str:
        _ = owner_id
        if not citations:
            return ""
        joined = "\n".join(f"- {c.snippet}" for c in citations[:5])
        return f"질문: {query}\n발견된 단서:\n{joined}"


@router.post("", response_model=SearchResponse)
async def search(payload: SearchRequest, db: DBSession, user: CurrentUser) -> SearchResponse:
    # voyage 키 미설정 시: embedder 는 None 을 돌려 vector 후보 생략, reranker 는 미장착 —
    # BM25 + RRF 순서로 degrade 하되 검색 자체는 항상 동작한다.
    voyage = get_voyage_client()
    index = PostgresHybridIndex(db, query_embedding_provider=make_query_embedder(voyage))
    use_case = HybridSearch(
        index=index,
        synthesizer=_ExtractiveSynthesizer(),
        reranker=VoyageReranker(voyage) if voyage is not None else None,
    )
    result = await use_case.execute(
        SearchQuery(
            text=payload.query,
            scope=payload.scope,
            owner_id=user,
        )
    )
    return SearchResponse(
        answer=result.answer,
        citations=[
            CitationDTO(mochi_item_id=c.mochi_item_id, snippet=c.snippet, score=c.score)
            for c in result.citations
        ],
        total_tokens=result.total_tokens,
        agent_run_id=result.agent_run_id,
    )
