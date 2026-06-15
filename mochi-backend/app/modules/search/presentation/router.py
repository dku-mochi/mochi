from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.core.deps import DBSession, get_voyage_client
from app.core.security import CurrentUser
from app.modules.search.application.hybrid_search import HybridSearch
from app.modules.search.domain.entities import (
    Citation,
    SearchQuery,
    SearchScope,
    SimilarReasonKind,
)
from app.modules.search.domain.ports import AnswerSynthesizer
from app.modules.search.infrastructure.postgres_index import PostgresHybridIndex
from app.modules.search.infrastructure.voyage_adapter import VoyageReranker, make_query_embedder

router = APIRouter(prefix="/search", tags=["search"])

# 상세 "비슷한 기록" 라우트 — 같은 search 모듈 소유, path 만 /mochi_items 로 노출
# (mochi_items 라우터가 search.infrastructure 를 import 하면 모듈 경계 위반이라 여기 둔다).
similar_router = APIRouter(prefix="/mochi_items", tags=["search"])

# voyage-3-large cosine 유사도 보수적 임계 — lab 벤치(rag-rerank-eval)로 튜닝 (DOMAIN_DESIGN §10.5).
# 0.6→0.7 상향: 0.6 은 의미상 약하게 가까운 항목까지 통과시켜 "관련 없는 기록"이 섞였다(사용자 리포트).
_SIMILAR_MIN_SCORE = 0.7


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


class SimilarReasonDTO(BaseModel):
    kind: SimilarReasonKind
    value: str | None = None


class SimilarItemDTO(BaseModel):
    mochi_item_id: UUID = Field(alias="mochiItemId")
    score: float
    reasons: list[SimilarReasonDTO]

    model_config = {"populate_by_name": True}


class SimilarItemsResponse(BaseModel):
    items: list[SimilarItemDTO]

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


@similar_router.get("/{mochi_item_id}/similar", response_model=SimilarItemsResponse)
async def get_similar_items(
    mochi_item_id: UUID,
    db: DBSession,
    user: CurrentUser,
    limit: int = 6,
) -> SimilarItemsResponse:
    """상세 화면 "비슷한 기록" — 대상 item 의 cosine 이웃 top-k (DOMAIN_DESIGN §10.5).

    자기 제외 + owner-scoped + 임계값(`_SIMILAR_MIN_SCORE`) 미달이면 빈 배열 + 같은 출처 URL
    dedup. 대상에 embedding 이 없으면(미색인·`VOYAGE_API_KEY` 미설정) 빈 배열로 degrade —
    iOS 가 섹션을 숨긴다. 응답은 id+score+reasons 만(카드 렌더는 iOS 로컬 lookup).
    """
    index = PostgresHybridIndex(db, query_embedding_provider=make_query_embedder(get_voyage_client()))
    items = await index.similar(
        owner_id=user,
        mochi_item_id=mochi_item_id,
        limit=max(1, min(limit, 20)),
        min_score=_SIMILAR_MIN_SCORE,
    )
    return SimilarItemsResponse(
        items=[
            SimilarItemDTO(
                mochi_item_id=it.mochi_item_id,
                score=it.score,
                reasons=[SimilarReasonDTO(kind=r.kind, value=r.value) for r in it.reasons],
            )
            for it in items
        ]
    )
