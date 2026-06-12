from collections.abc import Awaitable, Callable

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.search.domain.entities import Citation, SearchQuery
from app.modules.search.domain.ports import RetrievalIndex


class PostgresHybridIndex(RetrievalIndex):
    """
    Postgres + pgvector 를 단일 어댑터로 묶는다.

    - BM25는 Postgres `tsvector` + `ts_rank_cd` 로 근사
    - 벡터는 pgvector `<=>` 코사인 거리 (쿼리 임베딩은 voyage `input_type=query`)
    - 두 결과는 RRF로 합치며, 본 어댑터는 raw 후보 리스트만 반환
    - **모든 쿼리는 `owner_id` 로 필터링되어 cross-tenant 누설을 방지한다**
    - provider 가 ``None`` 을 반환하면(voyage 미설정·일시 장애) vector 후보는 빈 리스트 —
      파이프라인이 BM25 단독으로 degrade 한다 (검색이 외부 API 장애로 죽지 않는 계약)
    """

    def __init__(
        self,
        session: AsyncSession,
        *,
        query_embedding_provider: Callable[[str], Awaitable[list[float] | None]],
    ) -> None:
        self._session = session
        self._embed = query_embedding_provider

    async def bm25(self, query: SearchQuery) -> list[Citation]:
        if query.owner_id is None:
            return []
        sql = text(
            """
            SELECT id,
                   ts_rank_cd(
                       to_tsvector('simple', coalesce(summary,'') || ' ' || coalesce(text,'')),
                       plainto_tsquery('simple', :q)
                   ) AS score,
                   left(coalesce(summary, text, ''), 240) AS snippet
            FROM mochi_items
            WHERE owner_id = :owner_id
              AND deleted_at IS NULL
              AND to_tsvector('simple', coalesce(summary,'') || ' ' || coalesce(text,''))
                  @@ plainto_tsquery('simple', :q)
              AND (:scope = 'all'
                   OR EXISTS (SELECT 1 FROM intent_instances ii
                              WHERE ii.mochi_item_id = mochi_items.id AND ii.intent_type = :scope))
            ORDER BY score DESC
            LIMIT :k
            """
        ).bindparams(
            bindparam("q", query.text),
            bindparam("owner_id", query.owner_id),
            bindparam("scope", query.scope.value),
            bindparam("k", query.bm25_k),
        )
        rows = (await self._session.execute(sql)).all()
        return [Citation(mochi_item_id=row.id, snippet=row.snippet or "", score=float(row.score)) for row in rows]

    async def vector(self, query: SearchQuery) -> list[Citation]:
        if query.owner_id is None:
            return []
        embedding = await self._embed(query.text)
        if embedding is None:
            return []
        sql = text(
            """
            SELECT c.id AS mochi_item_id,
                   left(coalesce(c.summary, c.text, ''), 240) AS snippet,
                   1.0 - (e.embedding <=> CAST(:embedding AS vector)) AS score
            FROM embeddings e
            JOIN mochi_items c ON c.id = e.mochi_item_id
            WHERE c.owner_id = :owner_id
              AND c.deleted_at IS NULL
              AND (:scope = 'all'
                   OR EXISTS (SELECT 1 FROM intent_instances ii
                              WHERE ii.mochi_item_id = c.id AND ii.intent_type = :scope))
            ORDER BY e.embedding <=> CAST(:embedding AS vector)
            LIMIT :k
            """
        ).bindparams(
            bindparam("embedding", vector_literal(embedding)),
            bindparam("owner_id", query.owner_id),
            bindparam("scope", query.scope.value),
            bindparam("k", query.vector_k),
        )
        rows = (await self._session.execute(sql)).all()
        return [Citation(mochi_item_id=row.mochi_item_id, snippet=row.snippet or "", score=float(row.score)) for row in rows]


def vector_literal(embedding: list[float]) -> str:
    """pgvector text-form 직렬화 — ``CAST(:param AS vector)`` 에 문자열로 바인드한다.

    asyncpg 의 float 배열 바인드는 pgvector 확장 버전에 따라 array→vector cast 가
    없을 수 있어, 모든 버전에서 동작하는 canonical 경로(text→vector)를 쓴다.
    """
    return "[" + ",".join(map(str, embedding)) + "]"
