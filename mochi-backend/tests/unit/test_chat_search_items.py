"""SearchItemsTool 의 필터 조립 검증 — fake 세션으로 SQL 텍스트·바인드 파라미터를 캡처한다.

핵심은 시간 2축의 분리(실기기 버그 2026-06-10): ``date_from``/``date_to`` 는 저장 시각
(``captured_at``), ``occurs_from``/``occurs_to`` 는 발생일(instance payload deadline/date).
"내일 일정" 류 질문이 저장 시각 필터로 가면 항상 0건이 된다.
"""

from typing import Any
from uuid import uuid4

import pytest

from app.modules.conversations.infrastructure.tools.search_items import (
    _PARAMETERS,
    SearchItemsTool,
    _like_pattern,
    _parse_date_only,
)

pytestmark = pytest.mark.anyio

_OWNER = uuid4()


class _FakeResult:
    def all(self) -> list[Any]:
        return []


class _FakeSession:
    def __init__(self, captured: list[Any]):
        self._captured = captured

    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *args: Any) -> bool:
        return False

    async def execute(self, sql: Any) -> _FakeResult:
        self._captured.append(sql)
        return _FakeResult()


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


def test_like_pattern_escapes_wildcards() -> None:
    assert _like_pattern("100%") == "%100\\%%"
    assert _like_pattern("a_b") == "%a\\_b%"
    assert _like_pattern("back\\slash") == "%back\\\\slash%"


def test_parameters_schema_exposes_two_time_axes() -> None:
    props = _PARAMETERS["properties"]
    assert {"date_from", "date_to", "occurs_from", "occurs_to"} <= props.keys()
    # 모델 조향의 핵심: 저장 시각 필터 설명이 발생일 축으로 안내한다.
    assert "occurs_from" in props["date_from"]["description"]
