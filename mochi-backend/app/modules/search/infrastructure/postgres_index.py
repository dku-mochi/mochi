from collections.abc import Awaitable, Callable
from uuid import UUID

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.search.domain.entities import (
    Citation,
    SearchQuery,
    SimilarItem,
    SimilarReason,
    SimilarReasonKind,
)
from app.modules.search.domain.ports import RetrievalIndex

# 같은 출처 URL 이 여러 번 저장된 중복을 접고도 limit 을 채우도록 넉넉히 후보를 뽑는다.
_SIMILAR_CANDIDATE_FANOUT = 4


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
        return [
            Citation(mochi_item_id=row.id, snippet=row.snippet or "", score=float(row.score)) for row in rows
        ]

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
        return [
            Citation(mochi_item_id=row.mochi_item_id, snippet=row.snippet or "", score=float(row.score))
            for row in rows
        ]

    async def similar(
        self, *, owner_id: UUID, mochi_item_id: UUID, limit: int, min_score: float
    ) -> list[SimilarItem]:
        # seed = 대상 item 의 저장된 embedding. uncorrelated 서브쿼리로 DB 안에서만 다뤄
        # (벡터를 앱으로 꺼내 재직렬화하지 않는다 — pgvector 타입 변환·라운드트립 회피).
        # target 에 embedding 이 없으면(미색인·VOYAGE_API_KEY 미설정) 서브쿼리가 NULL → 0행.
        fanout = max(limit * _SIMILAR_CANDIDATE_FANOUT, limit)
        sql = text(
            """
            WITH target AS (
                SELECT e.embedding AS emb, c.url AS url
                FROM embeddings e
                JOIN mochi_items c ON c.id = e.mochi_item_id
                WHERE c.id = :target_id AND c.owner_id = :owner_id AND c.deleted_at IS NULL
                LIMIT 1
            )
            SELECT c.id AS mochi_item_id,
                   1.0 - (e.embedding <=> (SELECT emb FROM target)) AS score,
                   c.url AS url,
                   (SELECT url FROM target) AS target_url
            FROM embeddings e
            JOIN mochi_items c ON c.id = e.mochi_item_id
            WHERE c.owner_id = :owner_id
              AND c.deleted_at IS NULL
              AND c.id <> :target_id
              AND (SELECT emb FROM target) IS NOT NULL
              AND 1.0 - (e.embedding <=> (SELECT emb FROM target)) >= :min_score
              -- 민감 게이트 자리(privacy 필드 도입 시 한 줄 추가, TODO §5.1 / PRIVACY §9):
              --   AND c.sensitivity_level < (threshold 바인드 추가)
              -- ⚠️ 주석이라도 콜론 파라미터(콜론+이름)는 쓰지 말 것 — SQLAlchemy text() 가
              --    주석 안의 콜론 토큰도 bind param 으로 파싱해 매 쿼리가 깨진다(2026-06-14).
            ORDER BY e.embedding <=> (SELECT emb FROM target)
            LIMIT :fanout
            """
        ).bindparams(
            bindparam("target_id", mochi_item_id),
            bindparam("owner_id", owner_id),
            bindparam("min_score", min_score),
            bindparam("fanout", fanout),
        )
        rows = (await self._session.execute(sql)).all()
        if not rows:
            return []

        # 같은 출처 URL 중복 접기 — 가장 유사한 1건만 남긴다(이미 score 내림차순).
        deduped = []
        seen_urls: set[str] = set()
        for row in rows:
            if row.url is not None:
                if row.url in seen_urls:
                    continue
                seen_urls.add(row.url)
            deduped.append(row)
            if len(deduped) >= limit:
                break

        target_url = rows[0].target_url

        # sameIntent 근거 — 대상 + 후보들의 intent_type 을 한 번에 조회(후보 소수에만).
        ids = [mochi_item_id, *(row.mochi_item_id for row in deduped)]
        intent_sql = text(
            "SELECT mochi_item_id, intent_type FROM intent_instances "
            "WHERE owner_id = :owner_id AND mochi_item_id IN :ids"
        ).bindparams(
            bindparam("owner_id", owner_id),
            bindparam("ids", value=ids, expanding=True),
        )
        intents_by_item: dict[UUID, set[str]] = {}
        for irow in (await self._session.execute(intent_sql)).all():
            intents_by_item.setdefault(irow.mochi_item_id, set()).add(irow.intent_type)
        target_intents = intents_by_item.get(mochi_item_id, set())

        results = []
        for row in deduped:
            reasons: list[SimilarReason] = []
            if target_url is not None and row.url == target_url:
                reasons.append(SimilarReason(kind=SimilarReasonKind.SHARED_SOURCE, value=row.url))
            shared_intent = sorted(intents_by_item.get(row.mochi_item_id, set()) & target_intents)
            if shared_intent:
                reasons.append(SimilarReason(kind=SimilarReasonKind.SAME_INTENT, value=shared_intent[0]))
            results.append(
                SimilarItem(mochi_item_id=row.mochi_item_id, score=float(row.score), reasons=reasons)
            )
        return results


def vector_literal(embedding: list[float]) -> str:
    """pgvector text-form 직렬화 — ``CAST(:param AS vector)`` 에 문자열로 바인드한다.

    asyncpg 의 float 배열 바인드는 pgvector 확장 버전에 따라 array→vector cast 가
    없을 수 있어, 모든 버전에서 동작하는 canonical 경로(text→vector)를 쓴다.
    """
    return "[" + ",".join(map(str, embedding)) + "]"
