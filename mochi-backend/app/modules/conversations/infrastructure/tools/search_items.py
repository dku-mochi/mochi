"""search_items — 기록 검색 채팅 툴 (read-only, hybrid retrieval).

두 갈래 후보를 합쳐 ``rerank-2.5`` 로 최종 순위를 정한다 (lab/active/rag-rerank-eval
2026-06-12 — reranker 가 R@1 0.15→0.43, MRR 0.56→0.88 의 승부처):

- **키워드**: 단어별 substring(ILIKE AND) — 'simple' tsvector 토큰 동일성은 조사 붙은
  한국어("민수와" vs "민수")가 0건이 되기 때문(2026-06-10). 고유명사 exact 질의의 보험.
- **의미(vector)**: voyage-3-large 쿼리 임베딩 → pgvector 코사인 — 기록은 저장 당시
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

기존 ``search/postgres_index.py`` BM25 패턴을 따르되 ``deleted_at IS NULL`` (§3 불변식)
+ 구조화 필터를 더한다. detached run task 에서 불리므로 호출마다 자체 세션을 연다.
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
from app.shared.voyage import VoyageClient, VoyageError

log = get_logger("chat.search_items")

TOP_K = 8
SNIPPET_CHARS = 300
#: rerank 입력 후보 수 (갈래당) — 키워드 24 + 의미 24 를 합쳐 rerank-2.5 가 최종 limit 을 뽑는다.
RERANK_CANDIDATES = 24

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "query": {
            "type": "string",
            "description": (
                "Keyword(s) or a short phrase describing what the record is about. Matching is "
                "hybrid: exact words match directly, and semantic retrieval also surfaces records "
                "that mean the same thing in different words — so describe the thing naturally "
                "instead of guessing the saved vocabulary. Keep one concept per call. Omit to "
                "filter-only browse."
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

#: 키워드 매칭 대상 — 검색 가능한 텍스트 전부.
_HAYSTACK_SQL = "coalesce(m.summary,'') || ' ' || coalesce(m.text,'') || ' ' || coalesce(m.user_memo,'')"

#: 키워드당 substring 매칭 상한 — 그 이상은 노이즈 (plainto 의 AND 의미는 유지).
_MAX_KEYWORDS = 5

#: instance 의 "발생 시작일" — deadline 우선, 없으면 date (``ListUpcomingActionables`` 와 동일 우선순위).
#: payload 값이 free-text 라 앞 10자를 ISO 모양으로 정규화('/'·'.' → '-')해 사전식 비교한다.
_OCCURS_DATE_SQL = (
    "translate(left(coalesce(nullif(ii.payload->>'deadline',''), ii.payload->>'date'), 10), "
    "'./', '--')"
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


def _like_pattern(word: str) -> str:
    escaped = word.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


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
                   (SELECT coalesce(array_agg(DISTINCT ii.intent_type), ARRAY[]::varchar[])
                    FROM intent_instances ii WHERE ii.mochi_item_id = m.id) AS intents,
                   (SELECT coalesce(array_agg(ii.label), ARRAY[]::varchar[])
                    FROM intent_instances ii
                    WHERE ii.mochi_item_id = m.id AND ii.label IS NOT NULL) AS labels"""


class SearchItemsTool:
    name = "search_items"
    label = "기록을 뒤지고 있어요"
    description = (
        "Search the user's saved records (screenshots, links, notes). "
        "Returns id, snippet, intents, and captured time per record. "
        "Matching is hybrid — exact keywords plus semantic retrieval, so records phrased "
        "differently from the query are still found and ranked by relevance. "
        "Combine query and filters. Two time axes: date_from/date_to scope when a record "
        "was saved; occurs_from/occurs_to scope when its event happens or is due — asks about "
        "a period's plans or due work need occurs_*, because a plan for tomorrow was usually "
        "saved earlier. Always search before answering about the user's records. "
        "If a search comes back empty, one reframed retry (describe what the record is about, "
        "or relax filters) is enough before concluding nothing is saved."
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
        query = (args.get("query") or "").strip() or None
        intent_raw = args.get("intent_type")
        intent = intent_raw if isinstance(intent_raw, str) and intent_raw in {i.value for i in Intent} else None
        date_from = _parse_dt(args.get("date_from"))
        date_to = _parse_dt(args.get("date_to"))
        occurs_from = _parse_date_only(args.get("occurs_from"))
        occurs_to = _parse_date_only(args.get("occurs_to"))
        raw_limit = args.get("limit")
        # genai 가 숫자를 float 으로 줄 수 있다 — int/float 모두 수용.
        limit = (
            min(int(raw_limit), TOP_K)
            if isinstance(raw_limit, int | float) and int(raw_limit) > 0
            else TOP_K
        )

        # 구조화 필터 — 키워드·의미 두 갈래에 동일 적용된다.
        base_clauses = ["m.owner_id = :owner_id", "m.deleted_at IS NULL"]
        params: dict[str, Any] = {"owner_id": owner_id}
        # intent·발생일은 같은 instance 가 만족해야 한다 — EXISTS 하나로 합친다.
        # archived instance 도 매칭한다 — 의도된 동작: 완료된 할일·끝난 일정도 "기록"이고
        # 회상 질문("민수랑 언제 만나기로 했지?")의 정답은 종종 archived 쪽에 있다.
        instance_conds: list[str] = []
        if intent:
            instance_conds.append("ii.intent_type = :intent")
            params["intent"] = intent
        if occurs_from or occurs_to:
            instance_conds.append(_OCCURS_SHAPE_GUARD)
        if occurs_from:
            # 종료일 기준 — 기간형 일정은 끝나기 전까지 window 에 걸린다(점 일정은 종료=시작).
            instance_conds.append(f"{_OCCURS_END_DATE_SQL} >= :occurs_from")
            params["occurs_from"] = occurs_from
        if occurs_to:
            instance_conds.append(f"{_OCCURS_DATE_SQL} <= :occurs_to")
            params["occurs_to"] = occurs_to
        if instance_conds:
            base_clauses.append(
                "EXISTS (SELECT 1 FROM intent_instances ii "
                "WHERE ii.mochi_item_id = m.id AND " + " AND ".join(instance_conds) + ")"
            )
        if date_from:
            base_clauses.append("m.captured_at >= :date_from")
            params["date_from"] = date_from
        if date_to:
            base_clauses.append("m.captured_at < :date_to")
            params["date_to"] = date_to

        keyword_clauses = list(base_clauses)
        if query:
            # 'simple' tsvector 는 토큰 동일성만 본다 — 한국어는 조사가 붙어("민수와") 표제어
            # ("민수") 검색이 0건이 된다 (실기기 버그 2026-06-10). 매칭은 단어별 substring 으로
            # ('simple' 토큰 동일성의 상위집합), 랭킹은 BM25 근사(ts_rank_cd)를 유지한다.
            for idx, word in enumerate(query.split()[:_MAX_KEYWORDS]):
                keyword_clauses.append(f"{_HAYSTACK_SQL} ILIKE :kw{idx}")
                params[f"kw{idx}"] = _like_pattern(word)
            params["q"] = query  # 랭킹(ts_rank_cd) 전용

        # 의미 검색은 query 가 있고 voyage 가 살아 있을 때만 — 임베딩 실패는 키워드 단독 degrade.
        query_vector: list[float] | None = None
        if query and self._voyage is not None:
            try:
                query_vector = await self._voyage.embed_query(query)
            except VoyageError as exc:
                log.warning("chat.search_query_embed_failed", exception=str(exc))
        semantic = query_vector is not None
        # rerank 가 최종 순위를 정할 때만 갈래당 후보를 넓게 가져온다.
        params["k"] = RERANK_CANDIDATES if semantic else limit

        order = (
            # 조사 붙은 매칭은 rank 0 이라 captured_at 보조 정렬이 실질 순서가 된다.
            f"ts_rank_cd(to_tsvector('simple', {_HAYSTACK_SQL}), "
            "plainto_tsquery('simple', :q)) DESC, m.captured_at DESC"
            if query
            else "m.captured_at DESC"
        )
        keyword_sql = text(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM mochi_items m
            WHERE {" AND ".join(keyword_clauses)}
            ORDER BY {order}
            LIMIT :k
            """
        ).bindparams(*[bindparam(key, value) for key, value in params.items()])

        async with self._session_factory() as session:
            keyword_rows = list((await session.execute(keyword_sql)).all())
            vector_rows: list[Any] = []
            if semantic:
                vector_params = {
                    key: value
                    for key, value in params.items()
                    if key not in {"q"} and not key.startswith("kw")
                }
                vector_params["qvec"] = _vector_literal(query_vector or [])
                vector_sql = text(
                    f"""
                    SELECT {_SELECT_COLUMNS}
                    FROM embeddings e
                    JOIN mochi_items m ON m.id = e.mochi_item_id
                    WHERE {" AND ".join(base_clauses)}
                    ORDER BY e.embedding <=> CAST(:qvec AS vector)
                    LIMIT :k
                    """
                ).bindparams(*[bindparam(key, value) for key, value in vector_params.items()])
                vector_rows = list((await session.execute(vector_sql)).all())

        # 병합: 키워드 매치(모든 단어 포함 — 정밀) 먼저, 의미 후보는 뒤에 추가.
        merged = list(keyword_rows)
        seen = {row.id for row in keyword_rows}
        for row in vector_rows:
            if row.id not in seen:
                seen.add(row.id)
                merged.append(row)

        if semantic and query and len(merged) > 1:
            merged = await self._rerank(query, merged, limit)
        else:
            merged = merged[:limit]

        items = [
            {
                "id": str(row.id),
                "snippet": row.snippet or "",
                "captured_at": row.captured_at.isoformat(),
                "channel": row.channel,
                "intents": list(row.intents or []),
            }
            for row in merged
        ]
        return ChatToolResult(
            payload={"items": items, "count": len(items)},
            summary=f"기록 {len(items)}개를 찾았어요" if items else "맞는 기록을 못 찾았어요",
            compact={"items": [{"id": i["id"], "snippet": i["snippet"][:60]} for i in items[:3]]},
        )

    async def _rerank(self, query: str, candidates: list[Any], limit: int) -> list[Any]:
        """rerank-2.5 로 최종 순위 결정. 실패 시 병합 순서(키워드 우선) 그대로 truncate —
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


def _vector_literal(embedding: list[float]) -> str:
    """pgvector text-form 직렬화 — ``CAST(:qvec AS vector)`` 바인드용 (search 모듈과 동일 경로)."""
    return "[" + ",".join(map(str, embedding)) + "]"
