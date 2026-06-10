"""search_items — 기록 검색 채팅 툴 (read-only).

키워드는 BM25(tsvector) 근사, **구조화 필터가 본질**: "이번주 공부 기록" 류 대표 시나리오는
키워드가 아니라 시간 범위 + intent 필터 문제다(journal 2026-06-10). Hybrid Search 교체는
이 파일 내부 SQL 만 바꾸면 된다(인터페이스 동일 — search 모듈 §6.4 어댑터 교체 전례).

기존 ``search/postgres_index.py`` BM25 패턴을 따르되 두 가지를 더한다:
``deleted_at IS NULL`` (§3 불변식 — 기존 검색 쿼리의 누락은 별도 이슈) + 구조화 필터.
detached run task 에서 불리므로 호출마다 자체 세션을 연다.
"""

from collections.abc import Callable
from datetime import datetime
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.conversations.domain.ports import ChatToolResult
from app.shared.intent import Intent

TOP_K = 8
SNIPPET_CHARS = 300

_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "query": {
            "type": "string",
            "description": "Keyword(s) to match against record text. Omit to filter-only browse.",
        },
        "intent_type": {
            "type": "string",
            "enum": [i.value for i in Intent],
            "description": "Only records carrying this intent (schedule/todo/knowledge/memo).",
        },
        "date_from": {
            "type": "string",
            "description": "ISO date(time), inclusive — records captured at/after this moment.",
        },
        "date_to": {
            "type": "string",
            "description": "ISO date(time), exclusive — records captured before this moment.",
        },
        "limit": {"type": "integer", "description": f"Max results, 1-{TOP_K}."},
    },
}


_KST = ZoneInfo("Asia/Seoul")


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


class SearchItemsTool:
    name = "search_items"
    label = "기록을 뒤지고 있어요"
    description = (
        "Search the user's saved records (screenshots, links, notes). "
        "Returns id, snippet, intents, and captured time per record. "
        "Combine keyword and filters; use date range + intent_type for time-scoped asks "
        "like 'this week's study notes'. Always search before answering about the user's records."
    )
    parameters = _PARAMETERS

    def __init__(self, session_factory: Callable[[], AsyncSession] | async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        query = (args.get("query") or "").strip() or None
        intent_raw = args.get("intent_type")
        intent = intent_raw if isinstance(intent_raw, str) and intent_raw in {i.value for i in Intent} else None
        date_from = _parse_dt(args.get("date_from"))
        date_to = _parse_dt(args.get("date_to"))
        raw_limit = args.get("limit")
        # genai 가 숫자를 float 으로 줄 수 있다 — int/float 모두 수용.
        limit = (
            min(int(raw_limit), TOP_K)
            if isinstance(raw_limit, int | float) and int(raw_limit) > 0
            else TOP_K
        )

        clauses = ["m.owner_id = :owner_id", "m.deleted_at IS NULL"]
        params: dict[str, Any] = {"owner_id": owner_id, "k": limit}
        if query:
            clauses.append(
                "to_tsvector('simple', coalesce(m.summary,'') || ' ' || coalesce(m.text,'') || ' ' "
                "|| coalesce(m.user_memo,'')) @@ plainto_tsquery('simple', :q)"
            )
            params["q"] = query
        if intent:
            # archived instance 도 매칭한다 — 의도된 동작: 완료된 할일·끝난 일정도 "기록"이고
            # 회상 질문("민수랑 언제 만나기로 했지?")의 정답은 종종 archived 쪽에 있다.
            clauses.append(
                "EXISTS (SELECT 1 FROM intent_instances ii "
                "WHERE ii.mochi_item_id = m.id AND ii.intent_type = :intent)"
            )
            params["intent"] = intent
        if date_from:
            clauses.append("m.captured_at >= :date_from")
            params["date_from"] = date_from
        if date_to:
            clauses.append("m.captured_at < :date_to")
            params["date_to"] = date_to

        order = (
            "ts_rank_cd(to_tsvector('simple', coalesce(m.summary,'') || ' ' || coalesce(m.text,'') "
            "|| ' ' || coalesce(m.user_memo,'')), plainto_tsquery('simple', :q)) DESC"
            if query
            else "m.captured_at DESC"
        )
        sql = text(
            f"""
            SELECT m.id,
                   left(coalesce(m.summary, m.text, m.user_memo, ''), {SNIPPET_CHARS}) AS snippet,
                   m.captured_at,
                   m.channel,
                   (SELECT coalesce(array_agg(DISTINCT ii.intent_type), ARRAY[]::varchar[])
                    FROM intent_instances ii WHERE ii.mochi_item_id = m.id) AS intents
            FROM mochi_items m
            WHERE {" AND ".join(clauses)}
            ORDER BY {order}
            LIMIT :k
            """
        ).bindparams(*[bindparam(key, value) for key, value in params.items()])

        async with self._session_factory() as session:
            rows = (await session.execute(sql)).all()

        items = [
            {
                "id": str(row.id),
                "snippet": row.snippet or "",
                "captured_at": row.captured_at.isoformat(),
                "channel": row.channel,
                "intents": list(row.intents or []),
            }
            for row in rows
        ]
        return ChatToolResult(
            payload={"items": items, "count": len(items)},
            summary=f"기록 {len(items)}개를 찾았어요" if items else "맞는 기록을 못 찾았어요",
            compact={"items": [{"id": i["id"], "snippet": i["snippet"][:60]} for i in items[:3]]},
        )
