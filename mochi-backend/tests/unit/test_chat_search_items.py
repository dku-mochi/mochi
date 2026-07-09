"""SearchItemsTool 검증 — fake 세션으로 SQL 텍스트·바인드 파라미터를 캡처한다.

①필터 조립 — 핵심은 시간 2축의 분리(실기기 버그 2026-06-10): ``date_from``/``date_to`` 는
저장 시각(``captured_at``), ``occurs_from``/``occurs_to`` 는 발생일(instance payload
deadline/date). "내일 일정" 류 질문이 저장 시각 필터로 가면 항상 0건이 된다.

②hybrid retrieval (2026-06-12) — voyage 주입 시 키워드 + 의미(vector) 두 갈래 후보를
합쳐 rerank-2.5 가 최종 순위. voyage 미설정·임베딩/리랭크 실패는 키워드 단독 degrade.
"""

from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import pytest

from app.modules.conversations.infrastructure.tools.search_items import (
    _OCCURS_DATE_SQL,
    _OCCURS_END_DATE_SQL,
    _PARAMETERS,
    RERANK_CANDIDATES,
    SearchItemsTool,
    _parse_date_only,
)
from app.shared.voyage import RerankedDocument, VoyageError

pytestmark = pytest.mark.anyio

_OWNER = uuid4()


class _FakeResult:
    def __init__(self, rows: list[Any] | None = None):
        self._rows = rows or []

    def all(self) -> list[Any]:
        return self._rows


class _FakeSession:
    """execute 순서대로 ``results`` 를 돌려준다 (기본: 전부 빈 결과)."""

    def __init__(self, captured: list[Any], results: list[list[Any]] | None = None):
        self._captured = captured
        self._results = list(results or [])

    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *args: Any) -> bool:
        return False

    async def execute(self, sql: Any) -> _FakeResult:
        self._captured.append(sql)
        return _FakeResult(self._results.pop(0) if self._results else [])


class _Row:
    def __init__(self, snippet: str = "snippet", labels: list[str] | None = None):
        self.id = uuid4()
        self.snippet = snippet
        self.captured_at = datetime(2026, 6, 1, tzinfo=UTC)
        self.channel = "appDirectInput"
        self.intents = ["memo"]
        self.labels = labels or []
        self.importance = 3
        self.is_favorite = False


class _FakeVoyage:
    def __init__(
        self,
        *,
        embed_fail: bool = False,
        rerank_fail: bool = False,
        ranked: list[RerankedDocument] | None = None,
    ):
        self._embed_fail = embed_fail
        self._rerank_fail = rerank_fail
        self._ranked = ranked
        self.embed_calls: list[str] = []
        self.rerank_calls: list[dict[str, Any]] = []

    async def embed_query(self, text: str) -> list[float]:
        if self._embed_fail:
            raise VoyageError("down")
        self.embed_calls.append(text)
        return [0.1, 0.2]

    async def rerank(self, *, query: str, documents: list[str], top_k: int) -> list[RerankedDocument]:
        if self._rerank_fail:
            raise VoyageError("down")
        self.rerank_calls.append({"query": query, "documents": documents, "top_k": top_k})
        if self._ranked is not None:
            return self._ranked
        return [RerankedDocument(index=i, relevance_score=1.0) for i in range(min(top_k, len(documents)))]


async def _run(args: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    captured: list[Any] = []
    tool = SearchItemsTool(session_factory=lambda: _FakeSession(captured))
    await tool.run(owner_id=_OWNER, args=args)
    sql = captured[0]
    return str(sql), dict(sql.compile().params)


def test_parse_date_only_keeps_literal_calendar_date() -> None:
    # 모델이 'Z' 붙은 datetime 을 줘도 표기된 날짜 유지 — KST 환산하면 경계일이 하루 밀린다.
    assert _parse_date_only("2026-06-11T23:59:59Z") == "2026-06-11"
    assert _parse_date_only("2026-06-11") == "2026-06-11"
    assert _parse_date_only("내일") is None
    assert _parse_date_only(None) is None


async def test_occurs_window_builds_payload_date_exists_clause() -> None:
    sql, params = await _run({"occurs_from": "2026-06-11T00:00:00Z", "occurs_to": "2026-06-11"})
    assert "EXISTS" in sql
    assert "ii.payload->>'deadline'" in sql and "ii.payload->>'date'" in sql
    assert params["occurs_from"] == "2026-06-11"
    assert params["occurs_to"] == "2026-06-11"
    # 발생일 질문이 저장 시각 필터로 새지 않는다.
    assert "m.captured_at >=" not in sql and "m.captured_at <" not in sql


async def test_captured_window_still_filters_captured_at() -> None:
    sql, params = await _run({"date_from": "2026-06-11T00:00:00", "date_to": "2026-06-12T00:00:00"})
    assert "m.captured_at >= :date_from" in sql
    assert "m.captured_at < :date_to" in sql
    assert "EXISTS" not in sql


async def test_intent_and_occurs_must_match_same_instance() -> None:
    sql, params = await _run({"intent_type": "schedule", "occurs_from": "2026-06-11"})
    # EXISTS 절 하나 안에 intent·발생일 조건이 함께 있다 — 다른 instance 끼리 교차 매칭 금지.
    assert sql.count("EXISTS") == 1
    exists_clause = sql.split("EXISTS", 1)[1]
    assert "ii.intent_type = :intent" in exists_clause
    assert ":occurs_from" in exists_clause
    assert params["intent"] == "schedule"


async def test_occurs_from_compares_against_end_date_for_ranges() -> None:
    # 기간형 일정(end_date)은 끝나기 전까지 window 에 걸린다(overlap): occurs_from 은
    # 종료일(coalesce(end_date, 시작일)) 기준, occurs_to 는 시작일 기준.
    sql, _ = await _run({"occurs_from": "2026-06-11", "occurs_to": "2026-06-20"})
    assert "ii.payload->>'end_date'" in sql
    from_clause = sql.split(":occurs_from")[0]
    assert "coalesce(CASE WHEN" in from_clause  # 종료일 폴백이 occurs_from 비교에 쓰인다
    to_clause = sql.rsplit("<= :occurs_to", 1)[0].rsplit("AND", 1)[1]
    assert "end_date" not in to_clause  # occurs_to 는 시작일만 본다


def test_occurs_end_sql_converges_inverted_range_to_start() -> None:
    # 역전(end<start) 데이터는 점 일정으로 수렴(DOMAIN_DESIGN §4.2 불변식) —
    # CASE 가 end 모양 + end>=start 둘 다 만족할 때만 end 를 쓰고, 아니면 시작일 폴백.
    assert f">= {_OCCURS_DATE_SQL} " in _OCCURS_END_DATE_SQL
    assert _OCCURS_END_DATE_SQL.endswith(f"{_OCCURS_DATE_SQL})")


async def test_single_bound_occurs_includes_shape_guard() -> None:
    # 단일 bound 사전식 비교는 free-text("내일"·빈문자열·non-padded)가 오탐/누락된다 —
    # ISO 모양 guard 가 비정형 값을 전부 미매칭으로 수렴시킨다 (리뷰 P1).
    sql, _ = await _run({"occurs_from": "2026-06-11"})
    assert r"~ '^\d{4}-\d{2}-\d{2}'" in sql


async def test_invalid_occurs_value_is_ignored() -> None:
    sql, _ = await _run({"occurs_from": "다음주"})
    assert "occurs_from" not in sql


async def test_keyword_matches_by_substring_not_token_equality() -> None:
    # 'simple' tsvector 토큰 동일성은 조사 붙은 한국어("민수와")에서 표제어("민수") 검색이
    # 0건이 된다 — 매칭은 단어별 ILIKE, 랭킹만 ts_rank_cd 유지.
    sql, params = await _run({"query": "민수 홍대"})
    assert "@@ plainto_tsquery" not in sql
    assert "ILIKE :kw0" in sql and "ILIKE :kw1" in sql
    assert params["kw0"] == "%민수%" and params["kw1"] == "%홍대%"
    # 랭킹은 유지 + rank 0(조사 매칭) 동률은 최신순.
    assert "ts_rank_cd" in sql and "m.captured_at DESC" in sql


def test_parameters_schema_exposes_two_time_axes() -> None:
    props = _PARAMETERS["properties"]
    assert {"date_from", "date_to", "occurs_from", "occurs_to"} <= props.keys()
    # 모델 조향의 핵심: 저장 시각 필터 설명이 발생일 축으로 안내한다.
    assert "occurs_from" in props["date_from"]["description"]


# ---------- ② hybrid retrieval (키워드 + 의미 → rerank) ----------


async def test_semantic_path_runs_two_queries_and_reranks() -> None:
    kw_a, kw_b = _Row("키워드A"), _Row("키워드B")
    vec_b, vec_c = _Row("의미B"), _Row("의미C", labels=["라벨"])
    vec_b.id = kw_b.id  # 두 갈래에 모두 잡힌 기록 — 중복 제거 대상
    captured: list[Any] = []
    voyage = _FakeVoyage(
        ranked=[
            RerankedDocument(index=2, relevance_score=0.9),
            RerankedDocument(index=0, relevance_score=0.5),
        ]
    )
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured, results=[[kw_a, kw_b], [vec_b, vec_c]]),
        voyage=voyage,  # type: ignore[arg-type]
    )
    result = await tool.run(owner_id=_OWNER, args={"query": "보라카이 숙소"})

    # 두 SQL: 키워드(ILIKE) + 의미(embeddings 코사인). 의미 쿼리에는 키워드 절이 없다.
    assert len(captured) == 2
    keyword_sql, vector_sql = str(captured[0]), str(captured[1])
    assert "ILIKE" in keyword_sql and "embeddings" not in keyword_sql
    assert "embeddings e" in vector_sql and "ILIKE" not in vector_sql
    assert "CAST(:qvec AS vector)" in vector_sql
    # 두 갈래 모두 owner·soft-delete 가드 유지.
    assert "m.owner_id = :owner_id" in vector_sql and "m.deleted_at IS NULL" in vector_sql
    # rerank 가 최종 순위를 정하므로 갈래당 후보를 넓게 가져온다.
    assert dict(captured[0].compile().params)["k"] == RERANK_CANDIDATES

    # RRF 융합: kw_b 는 두 갈래(키워드 rank2 + 벡터 rank1, 둘 다 1-based)에 들어 점수 누적 → 최상위.
    # [kw_b, kw_a, vec_c] → rerank [2, 0] → [vec_c, kw_b]. rerank 문서엔 라벨 동봉.
    assert [i["id"] for i in result.payload["items"]] == [str(vec_c.id), str(kw_b.id)]
    assert voyage.rerank_calls[0]["documents"] == ["키워드B", "키워드A", "의미C 라벨"]
    assert voyage.embed_calls == ["보라카이 숙소"]


async def test_multi_query_fuses_candidates_and_reranks_once() -> None:
    # 두 query — 각각 키워드+벡터(총 4 SQL). RRF 가 네 리스트를 한 점수로 융합하고,
    # rerank 는 합쳐진 query 로 단 한 번 호출된다(query 수배가 아니라 1회 — 비용 bound).
    a, b = _Row("A 기록"), _Row("B 기록")
    captured: list[Any] = []
    voyage = _FakeVoyage(ranked=[RerankedDocument(index=0, relevance_score=0.9)])
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(
            captured,
            results=[[a], [a], [b], [b]],  # q1 키워드/벡터=a, q2 키워드/벡터=b
        ),
        voyage=voyage,  # type: ignore[arg-type]
    )
    result = await tool.run(owner_id=_OWNER, args={"queries": ["민수 약속", "성수 카페"]})

    assert len(captured) == 4  # query 2개 × (키워드 + 벡터)
    assert voyage.embed_calls == ["민수 약속", "성수 카페"]  # query 당 임베딩 1회
    assert len(voyage.rerank_calls) == 1  # 융합 후 단 1회
    assert voyage.rerank_calls[0]["query"] == "민수 약속 | 성수 카페"
    assert result.payload["count"] >= 1


async def test_query_count_is_capped() -> None:
    # _MAX_QUERIES(4) 초과분은 잘린다 — 과다 분해의 임베딩/SQL 비용 폭주 방지.
    captured: list[Any] = []
    voyage = _FakeVoyage()
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured),
        voyage=voyage,  # type: ignore[arg-type]
    )
    await tool.run(owner_id=_OWNER, args={"queries": [f"q{i}" for i in range(7)]})
    assert len(voyage.embed_calls) == 4  # 7개 줘도 4개만


async def test_embed_failure_degrades_to_keyword_only() -> None:
    rows = [_Row("키워드만")]
    captured: list[Any] = []
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured, results=[rows]),
        voyage=_FakeVoyage(embed_fail=True),  # type: ignore[arg-type]
    )
    result = await tool.run(owner_id=_OWNER, args={"query": "민수", "limit": 5})
    assert len(captured) == 1  # vector 쿼리 자체가 안 나간다
    assert dict(captured[0].compile().params)["k"] == 5  # 후보 확장 없이 limit 그대로
    assert [i["snippet"] for i in result.payload["items"]] == ["키워드만"]


async def test_rerank_failure_falls_back_to_keyword_first_order() -> None:
    kw, vec = _Row("키워드"), _Row("의미")
    captured: list[Any] = []
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured, results=[[kw], [vec]]),
        voyage=_FakeVoyage(rerank_fail=True),  # type: ignore[arg-type]
    )
    result = await tool.run(owner_id=_OWNER, args={"query": "민수", "limit": 2})
    # 키워드 매치(전 단어 포함 — 정밀) 우선, 의미 후보는 뒤에.
    assert [i["id"] for i in result.payload["items"]] == [str(kw.id), str(vec.id)]


async def test_filter_only_browse_skips_semantic_path() -> None:
    captured: list[Any] = []
    voyage = _FakeVoyage()
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured),
        voyage=voyage,  # type: ignore[arg-type]
    )
    await tool.run(owner_id=_OWNER, args={"intent_type": "schedule"})
    assert len(captured) == 1
    assert voyage.embed_calls == [] and voyage.rerank_calls == []


async def test_semantic_filters_apply_to_vector_query_too() -> None:
    captured: list[Any] = []
    tool = SearchItemsTool(
        session_factory=lambda: _FakeSession(captured, results=[[], [_Row()]]),
        voyage=_FakeVoyage(),  # type: ignore[arg-type]
    )
    await tool.run(
        owner_id=_OWNER,
        args={"query": "약속", "intent_type": "schedule", "occurs_from": "2026-06-11"},
    )
    vector_sql = str(captured[1])
    # 구조화 필터(intent+발생일 EXISTS)가 의미 갈래에도 동일 적용된다.
    assert "ii.intent_type = :intent" in vector_sql
    assert ":occurs_from" in vector_sql
