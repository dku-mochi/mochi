from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.core.deps import DBSession
from app.core.security import CurrentUser
from app.modules.search.application.hybrid_search import HybridSearch
from app.modules.search.domain.entities import Citation, SearchQuery, SearchScope
from app.modules.search.domain.ports import AnswerSynthesizer
from app.modules.search.infrastructure.postgres_index import PostgresHybridIndex, naive_embed

router = APIRouter(prefix="/search", tags=["search"])


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=512)
    scope: SearchScope = SearchScope.ALL


class CitationDTO(BaseModel):
    capture_id: UUID = Field(alias="captureId")
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
    index = PostgresHybridIndex(db, query_embedding_provider=naive_embed)
    use_case = HybridSearch(index=index, synthesizer=_ExtractiveSynthesizer())
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
            CitationDTO(capture_id=c.capture_id, snippet=c.snippet, score=c.score)
            for c in result.citations
        ],
        total_tokens=result.total_tokens,
        agent_run_id=result.agent_run_id,
    )
