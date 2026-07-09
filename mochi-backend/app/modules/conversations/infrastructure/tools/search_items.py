"""search_items — 기록 검색 채팅 툴 (read-only, hybrid retrieval).

두 갈래 후보를 합쳐 ``rerank-2.5`` 로 최종 순위를 정한다 (lab/active/rag-rerank-eval
2026-06-12 — reranker 가 R@1 0.15→0.43, MRR 0.56→0.88 의 승부처):

- **키워드**: 단어별 substring(ILIKE AND) — 'simple' tsvector 토큰 동일성은 조사 붙은
  한국어("민수와" vs "민수")가 0건이 되기 때문(2026-06-10). 고유명사 exact 질의의 보험.
- **의미(vector)**: voyage-4-large 쿼리 임베딩 → pgvector 코사인 — 기록은 저장 당시
  어휘로 말하므로, 질문 어휘가 달라도 의미로 회수한다 (어휘 불일치를 프롬프트의
  재검색 지시 대신 retrieval 이 흡수).

voyage 미설정·일시 장애 시 키워드 단독으로 degrade 한다 — 채팅 검색이 외부 API 장애로
죽지 않는다. **구조화 필터가 본질**: "이번주 공부 기록" 류 대표 시나리오는 키워드가
아니라 시간 범위 + intent 필터 문제다(journal 2026-06-10). 필터는 두 갈래에 동일하게
적용된다.

시간 축은 둘이다: ``date_from``/``date_to`` 는 **저장 시각**(``captured_at``),
``occurs_from``/``occurs_to`` 는 **발생일**(instance payload deadline/date). "내일 일정" 류
질문에 저장 시각 필터를 쓰면 미래에 캡처된 기록을 찾는 셈이라 항상 0건이다 (실기기 버그
2026-06-10).

키워드 매칭식·RRF·vector 직렬화는 ``app.shared.retrieval`` 공유 커널이 단일 원천이다
(``/search`` RAG 경로와 문자 그대로 같은 구현). 여기서 더하는 것은 ``deleted_at IS NULL``
(§3 불변식) + 구조화 필터 + 멀티쿼리 융합이다. detached run task 에서 불리므로 호출마다
자체 세션을 연다.
"""

from collections.abc import Callable
from datetime import datetime
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.logging import get_logger
from app.modules.conversations.domain.ports import ChatToolResult
from app.shared.intent import Intent
from app.shared.retrieval import keyword_match, reciprocal_rank_fusion, vector_literal
from app.shared.voyage import VoyageClient, VoyageError

log = get_logger("chat.search_items")

#: 한 검색이 회수하는 상한. Gemini 100만+ 컨텍스트에서 8은 회상·브라우징(정답 다수) 질문의 재현율
#: 병목이라 상향했다 — 후보를 넓게 돌려 모델이 스스로 취사하게 한다(기록은 값진 컨텍스트). 실측은
#: rag-rerank-eval 코퍼스가 @10 천장이라 이 축을 못 재므로(FINDINGS 한계), 코퍼스 1000+ 확장 후로 미룸.
TOP_K = 25
SNIPPET_CHARS = 300
#: rerank 입력 후보 수 (갈래당) — 키워드 50 + 의미 50 을 합쳐 rerank-2.5 가 최종 limit 을 뽑는다.
#: 후보 50 은 rag-rerank-eval 파이프라인 C(RRF Top50→rerank)가 이미 검증한 폭이다. 확대 비용은
#: DB LIMIT + rerank 입력 토큰(최대 100 문서)뿐 — 재현율 이득이 이를 정당화한다.
RERANK_CANDIDATES = 50

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "One or more short phrases, each describing one thing a record is about. Matching "
                "is hybrid: exact words match directly, and semantic retrieval also surfaces "
                "records that mean the same thing in different words — so describe the thing "
                "naturally instead of guessing the saved vocabulary. Put one concept per string, "
                "and pass several at once when the ask spans distinct things (a person, a place, "
                "a topic) — results are fused across them. Omit (empty) to filter-only browse."
            ),
        },
        "intent_type": {
            "type": "string",
            "enum": [i.value for i in Intent],
            "description": (
                "Only records carrying this intent (schedule/todo/knowledge/memo). Leave unset "
                "for broad asks — a question about a period's plans spans schedule and todo "
                "records, and filtering to one kind silently drops the rest. The user doesn't "
                "know these categories, so their own word for a kind is not a reliable signal "
                "for this filter: set it only when you are sure the ask is about exactly one kind."
            ),
        },
        "date_from": {
            "type": "string",
            "description": (
                "ISO date(time), inclusive — records *captured* (saved) at/after this moment. "
                "This is save time, not event time: a plan for tomorrow was usually saved "
                "earlier, so use occurs_from/occurs_to for when-it-happens asks."
            ),
        },
        "date_to": {
            "type": "string",
            "description": "ISO date(time), exclusive — records captured before this moment.",
        },
        "occurs_from": {
            "type": "string",
            "description": (
                "ISO date, inclusive — records whose event happens or is due on/after this day "
                "(matched against intent instance payload date/deadline). Use for any ask about "
                "what happens, is planned, or is due within a period."
            ),
        },
        "occurs_to": {
            "type": "string",
            "description": "ISO date, inclusive — events happening/due on/before this day.",
        },
        "limit": {"type": "integer", "description": f"Max results, 1-{TOP_K}."},
    },
}


_KST = ZoneInfo("Asia/Seoul")

#: 키워드 매칭 대상 — 검색 가능한 텍스트 전부. (매칭식·RRF 자체는 app.shared.retrieval 단일 원천)
_HAYSTACK_SQL = "coalesce(m.summary,'') || ' ' || coalesce(m.text,'') || ' ' || coalesce(m.user_memo,'')"

#: 한 호출에 받는 query 상한 — 여러 정보 욕구를 한 번에(resource_finder `_MAX_QUERIES` 선례).
#: 그 이상 분해는 비용만 늘고 RRF 융합 변별력이 떨어진다.
_MAX_QUERIES = 4

#: instance 의 "발생 시작일" — deadline 우선, 없으면 date (``ListUpcomingActionables`` 와 동일 우선순위).
#: payload 값이 free-text 라 앞 10자를 ISO 모양으로 정규화('/'·'.' → '-')해 사전식 비교한다.
_OCCURS_DATE_SQL = (
    "translate(left(coalesce(nullif(ii.payload->>'deadline',''), ii.payload->>'date'), 10), './', '--')"
)
#: 사전식 비교는 zero-padded ISO 모양에서만 안전하다 — 단일 bound 호출에서 한글("내일")·
#: 빈문자열·non-padded("2026.6.1") free-text 가 오탐/누락되므로, 모양이 어긋난 값은 전부
#: 조용히 미매칭으로 수렴시킨다 (``_parse_deadline`` 의 graceful 실패와 동일 철학, 리뷰 P1).
_OCCURS_SHAPE_GUARD = rf"{_OCCURS_DATE_SQL} ~ '^\d{{4}}-\d{{2}}-\d{{2}}'"
_OCCURS_END_RAW_SQL = "translate(left(nullif(ii.payload->>'end_date',''), 10), './', '--')"
#: 발생 "종료일" — 기간형 일정의 ``end_date``. 모양이 어긋나거나 없거나 **시작보다 앞서면**
#: (역전 데이터) 시작일로 수렴 — "역전·비정형 end 는 점 일정" 불변식 (DOMAIN_DESIGN §4.2).
#: 기간 질의는 overlap 의미: 시작 <= occurs_to AND 종료 >= occurs_from.
_OCCURS_END_DATE_SQL = (
    rf"coalesce(CASE WHEN {_OCCURS_END_RAW_SQL} ~ '^\d{{4}}-\d{{2}}-\d{{2}}' "
    rf"AND {_OCCURS_END_RAW_SQL} >= {_OCCURS_DATE_SQL} "
    rf"THEN {_OCCURS_END_RAW_SQL} END, {_OCCURS_DATE_SQL})"
)


def _parse_queries(args: dict[str, Any]) -> list[str]:
    """queries(list[str]) 우선, 단일 query(str) 하위호환. 공백 정리·빈 항목 제거 후 최대 _MAX_QUERIES.

    genai 가 array 를 단일 문자열로 줄 수도 있어 str 도 단수로 수용한다.
    """
    raw = args.get("queries")
    if raw is None:
        single = args.get("query")
        raw = [single] if single else []
    elif isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    for item in raw:
        if isinstance(item, str):
            stripped = item.strip()
            if stripped and stripped not in out:  # 중복 query 제거 — 비용·RRF 중복가중 방지
                out.append(stripped)
        if len(out) >= _MAX_QUERIES:
            break
    return out


def _parse_dt(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    # 프롬프트가 {now} 를 KST 로 주므로 모델의 offset 없는 ISO 는 KST 의도다 — naive 를
    # 그대로 두면 asyncpg 가 UTC 로 간주해 "오늘" window 가 9시간 밀린다 (리뷰 P1).
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_KST)
    return parsed


def _parse_date_only(raw: Any) -> str | None:
    """occurs_* 인자 → 'YYYY-MM-DD'. datetime 이 와도 표기된 달력 날짜만 취한다 — 모델이
    'Z' 를 붙여도 의도는 그 날짜라서, 타임존 환산을 하면 경계일이 하루 밀린다."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw).date().isoformat()
    except ValueError:
        return None


#: 두 갈래 공통 SELECT 컬럼 — labels 는 rerank 문서 텍스트(summary+labels, 실험 고정 조건)용.
_SELECT_COLUMNS = f"""m.id,
                   left(coalesce(m.summary, m.text, m.user_memo, ''), {SNIPPET_CHARS}) AS snippet,
                   m.captured_at,
                   m.channel,
                   m.importance,
                   m.is_favorite,
                   (SELECT coalesce(array_agg(DISTINCT ii.intent_type), ARRAY[]::varchar[])
                    FROM intent_instances ii WHERE ii.mochi_item_id = m.id) AS intents,
                   (SELECT coalesce(array_agg(ii.label), ARRAY[]::varchar[])
                    FROM intent_instances ii
                    WHERE ii.mochi_item_id = m.id AND ii.label IS NOT NULL) AS labels"""


class SearchItemsTool:
    name = "search_items"
    label = "기록을 뒤지고 있어요"
    description = (
        "Search the user's saved records (screenshots, links, notes) — your only window into "
        "their life. Call this first on nearly every turn: questions, vague recalls, requests "
        "for ideas, plans, or recommendations — even when the message sounds generic, their "
        "saved tastes, wishlists, places, and deadlines are what make the answer theirs. "
        "Matching is hybrid — exact keywords plus semantic retrieval — so describe what the "
        "record would be about in natural language; records phrased differently are still "
        "found. An ask that holds several distinct information needs is still one call: pass "
        "each need as its own string in `queries` and the results are fused. Combine queries "
        "and filters. Two time axes: "
        "date_from/date_to scope when a record was saved; occurs_from/occurs_to scope when its "
        "event happens or is due — asks about a period's plans or due work need occurs_*, "
        "because a plan for tomorrow was usually saved earlier. If a call comes back empty, "
        "one reframed retry (describe what the record is about, or relax filters) is enough "
        "for that need before concluding nothing is saved. Returns id, snippet, intents, "
        "captured time, importance, and whether the user favorited it per record — a favorited "
        "or high-importance record is a strong signal the user cares about it."
    )
    parameters = _PARAMETERS

    def __init__(
        self,
        session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession],
        voyage: VoyageClient | None = None,
    ):
        self._session_factory = session_factory
        self._voyage = voyage

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        queries = _parse_queries(args)
        intent_raw = args.get("intent_type")
        intent = (
            intent_raw if isinstance(intent_raw, str) and intent_raw in {i.value for i in Intent} else None
        )
        date_from = _parse_dt(args.get("date_from"))
        date_to = _parse_dt(args.get("date_to"))
        occurs_from = _parse_date_only(args.get("occurs_from"))
        occurs_to = _parse_date_only(args.get("occurs_to"))
        raw_limit = args.get("limit")
        # genai 가 숫자를 float 으로 줄 수 있다 — int/float 모두 수용.
        limit = (
            min(int(raw_limit), TOP_K) if isinstance(raw_limit, int | float) and int(raw_limit) > 0 else TOP_K
        )

        # 구조화 필터 — 모든 query 의 키워드·의미 갈래에 동일 적용된다.
        base_clauses = ["m.owner_id = :owner_id", "m.deleted_at IS NULL"]
        base_params: dict[str, Any] = {"owner_id": owner_id}
        # intent·발생일은 같은 instance 가 만족해야 한다 — EXISTS 하나로 합친다.
        # archived instance 도 매칭한다 — 의도된 동작: 완료된 할일·끝난 일정도 "기록"이고
        # 회상 질문("민수랑 언제 만나기로 했지?")의 정답은 종종 archived 쪽에 있다.
        instance_conds: list[str] = []
        if intent:
            instance_conds.append("ii.intent_type = :intent")
            base_params["intent"] = intent
        if occurs_from or occurs_to:
            instance_conds.append(_OCCURS_SHAPE_GUARD)
        if occurs_from:
            # 종료일 기준 — 기간형 일정은 끝나기 전까지 window 에 걸린다(점 일정은 종료=시작).
            instance_conds.append(f"{_OCCURS_END_DATE_SQL} >= :occurs_from")
            base_params["occurs_from"] = occurs_from
        if occurs_to:
            instance_conds.append(f"{_OCCURS_DATE_SQL} <= :occurs_to")
            base_params["occurs_to"] = occurs_to
        if instance_conds:
            base_clauses.append(
                "EXISTS (SELECT 1 FROM intent_instances ii "
                "WHERE ii.mochi_item_id = m.id AND " + " AND ".join(instance_conds) + ")"
            )
        if date_from:
            base_clauses.append("m.captured_at >= :date_from")
            base_params["date_from"] = date_from
        if date_to:
            base_clauses.append("m.captured_at < :date_to")
            base_params["date_to"] = date_to

        # query 당 의미검색 임베딩 — voyage 가 살아 있고 그 query 가 임베딩됐을 때만 벡터 갈래를 켠다.
        # 임베딩 실패는 그 query 만 키워드 단독으로 degrade (검색이 외부 API 장애로 죽지 않는다).
        query_vectors: dict[str, list[float]] = {}
        if queries and self._voyage is not None:
            for q in queries:
                try:
                    query_vectors[q] = await self._voyage.embed_query(q)
                except VoyageError as exc:
                    log.warning("chat.search_query_embed_failed", exception=str(exc))
        semantic = bool(query_vectors)
        # RRF 융합·rerank 가 최종 순위를 정할 때만 갈래당 후보를 넓게 가져온다.
        fanout = RERANK_CANDIDATES if (semantic or len(queries) > 1) else limit

        async with self._session_factory() as session:
            if not queries:
                merged = await self._filter_only(session, base_clauses, base_params, limit)
            else:
                # query 별 (키워드 + 의미) 순위 리스트를 모아 RRF 로 융합한다 — 단일 query 면
                # 키워드+벡터 두 리스트, N query 면 최대 2N 리스트가 한 점수로 합쳐진다.
                ranked_lists: list[list[Any]] = []
                for q in queries:
                    ranked_lists.append(
                        await self._keyword_candidates(session, base_clauses, base_params, q, fanout)
                    )
                    if q in query_vectors:
                        ranked_lists.append(
                            await self._vector_candidates(
                                session, base_clauses, base_params, query_vectors[q], fanout
                            )
                        )
                fused = reciprocal_rank_fusion(ranked_lists, id_of=lambda row: row.id)
                merged = [row for row, _ in fused]

        # 의미 갈래가 있을 때만 rerank — 융합 query 는 모든 query 를 합쳐 멀티 측면을 함께 본다.
        if semantic and queries and len(merged) > 1:
            merged = await self._rerank(" | ".join(queries), merged[:RERANK_CANDIDATES], limit)
        else:
            merged = merged[:limit]

        items = [
            {
                "id": str(row.id),
                "snippet": row.snippet or "",
                "captured_at": row.captured_at.isoformat(),
                "channel": row.channel,
                "intents": list(row.intents or []),
                "importance": row.importance,
                "is_favorite": row.is_favorite,
            }
            for row in merged
        ]
        return ChatToolResult(
            payload={"items": items, "count": len(items)},
            summary=f"기록 {len(items)}개를 찾았어요" if items else "맞는 기록을 못 찾았어요",
            # 과거 턴 재주입본 — full 결과는 현재 턴에만 남으므로 compact 가 멀티턴 회수의 실질 창이다.
            compact={"items": [{"id": i["id"], "snippet": i["snippet"][:120]} for i in items[:10]]},
        )

    async def _keyword_candidates(
        self,
        session: AsyncSession,
        base_clauses: list[str],
        base_params: dict[str, Any],
        query: str,
        k: int,
    ) -> list[Any]:
        """단어별 substring(ILIKE AND) 매칭 — 'simple' tsvector 가 조사 붙은 한국어("민수와" vs
        "민수")를 0건 만드는 회귀(2026-06-10)의 보험. 랭킹은 BM25 근사(ts_rank_cd).
        매칭식은 공유 커널(app.shared.retrieval.keyword_match) 단일 원천 — /search 와 동일."""
        km = keyword_match(_HAYSTACK_SQL, query)
        clauses = [*base_clauses, *km.clauses]
        params = {**base_params, **km.params, "k": k}
        sql = text(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM mochi_items m
            WHERE {" AND ".join(clauses)}
            ORDER BY {km.rank_sql} DESC, m.captured_at DESC
            LIMIT :k
            """
        ).bindparams(*[bindparam(key, value) for key, value in params.items()])
        return list((await session.execute(sql)).all())

    async def _vector_candidates(
        self,
        session: AsyncSession,
        base_clauses: list[str],
        base_params: dict[str, Any],
        query_vector: list[float],
        k: int,
    ) -> list[Any]:
        """voyage 쿼리 임베딩 → pgvector 코사인. 기록은 저장 당시 어휘로 말하므로 질문
        어휘가 달라도 의미로 회수한다."""
        params = dict(base_params)
        params["qvec"] = vector_literal(query_vector)
        params["k"] = k
        sql = text(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM embeddings e
            JOIN mochi_items m ON m.id = e.mochi_item_id
            WHERE {" AND ".join(base_clauses)}
            ORDER BY e.embedding <=> CAST(:qvec AS vector)
            LIMIT :k
            """
        ).bindparams(*[bindparam(key, value) for key, value in params.items()])
        return list((await session.execute(sql)).all())

    async def _filter_only(
        self,
        session: AsyncSession,
        base_clauses: list[str],
        base_params: dict[str, Any],
        limit: int,
    ) -> list[Any]:
        """query 없는 browse — 구조화 필터만, 최신 저장순."""
        params = dict(base_params)
        params["k"] = limit
        sql = text(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM mochi_items m
            WHERE {" AND ".join(base_clauses)}
            ORDER BY m.captured_at DESC
            LIMIT :k
            """
        ).bindparams(*[bindparam(key, value) for key, value in params.items()])
        return list((await session.execute(sql)).all())

    async def _rerank(self, query: str, candidates: list[Any], limit: int) -> list[Any]:
        """rerank-2.5 로 최종 순위 결정. 실패 시 RRF 융합 순서 그대로 truncate —
        리랭크 장애가 검색을 죽이지 않는다."""
        assert self._voyage is not None
        documents = [
            " ".join(part for part in [row.snippet or "", *(row.labels or [])] if part) or " "
            for row in candidates
        ]
        try:
            ranked = await self._voyage.rerank(query=query, documents=documents, top_k=limit)
        except VoyageError as exc:
            log.warning("chat.search_rerank_failed", exception=str(exc))
            return candidates[:limit]
        return [candidates[r.index] for r in ranked if 0 <= r.index < len(candidates)]
