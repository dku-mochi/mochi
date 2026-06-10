"""search_items — 기록 검색 채팅 툴 (read-only).

키워드 매칭은 단어별 substring(ILIKE), 랭킹은 BM25(tsvector) 근사 — 'simple' 사전은 토큰
동일성만 봐서 조사 붙은 한국어("민수와" vs "민수")가 0건이 되기 때문(2026-06-10).
**구조화 필터가 본질**: "이번주 공부 기록" 류 대표 시나리오는 키워드가 아니라 시간 범위 +
intent 필터 문제다(journal 2026-06-10). Hybrid Search 교체는 이 파일 내부 SQL 만 바꾸면
된다(인터페이스 동일 — search 모듈 §6.4 어댑터 교체 전례).

시간 축은 둘이다: ``date_from``/``date_to`` 는 **저장 시각**(``captured_at``),
``occurs_from``/``occurs_to`` 는 **발생일**(instance payload deadline/date). "내일 일정" 류
질문에 저장 시각 필터를 쓰면 미래에 캡처된 기록을 찾는 셈이라 항상 0건이다 (실기기 버그
2026-06-10).

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
            "description": (
                "Only records carrying this intent (schedule/todo/knowledge/memo). Leave unset "
                "for broad asks — a question about a period's plans spans schedule and todo "
                "records, and filtering to one kind silently drops the rest. The user doesn't "
                "know these categories, so their own word for a kind (\"메모\", \"할 일\") is "
                "not a reliable signal for this filter: set it only when you are sure the ask is "
                "about exactly one kind."
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


class SearchItemsTool:
    name = "search_items"
    label = "기록을 뒤지고 있어요"
    description = (
        "Search the user's saved records (screenshots, links, notes). "
        "Returns id, snippet, intents, and captured time per record. "
        "Combine keyword and filters. Two time axes: date_from/date_to scope when a record "
        "was saved; occurs_from/occurs_to scope when its event happens or is due — asks about "
        "a period's plans or due work need occurs_*, because a plan for tomorrow was usually "
        "saved earlier. Always search before answering about the user's records."
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
        occurs_from = _parse_date_only(args.get("occurs_from"))
        occurs_to = _parse_date_only(args.get("occurs_to"))
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
            # 'simple' tsvector 는 토큰 동일성만 본다 — 한국어는 조사가 붙어("민수와") 표제어
            # ("민수") 검색이 0건이 된다 (실기기 버그 2026-06-10). 매칭은 단어별 substring 으로
            # ('simple' 토큰 동일성의 상위집합), 랭킹은 BM25 근사(ts_rank_cd)를 유지한다.
            for idx, word in enumerate(query.split()[:_MAX_KEYWORDS]):
                clauses.append(f"{_HAYSTACK_SQL} ILIKE :kw{idx}")
                params[f"kw{idx}"] = _like_pattern(word)
            params["q"] = query  # 랭킹(ts_rank_cd) 전용
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
            clauses.append(
                "EXISTS (SELECT 1 FROM intent_instances ii "
                "WHERE ii.mochi_item_id = m.id AND " + " AND ".join(instance_conds) + ")"
            )
        if date_from:
            clauses.append("m.captured_at >= :date_from")
            params["date_from"] = date_from
        if date_to:
            clauses.append("m.captured_at < :date_to")
            params["date_to"] = date_to

        order = (
            # 조사 붙은 매칭은 rank 0 이라 captured_at 보조 정렬이 실질 순서가 된다.
            f"ts_rank_cd(to_tsvector('simple', {_HAYSTACK_SQL}), "
            "plainto_tsquery('simple', :q)) DESC, m.captured_at DESC"
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
