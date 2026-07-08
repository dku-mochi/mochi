"""app.shared.retrieval — hybrid retrieval 커널의 랭킹 프리미티브 검증.

두 검색 경로(``/search`` RAG · 채팅/분석 agent ``search_items``)가 공유하는 단일 원천이므로,
키워드 매칭식·RRF 융합의 계약은 여기서 못 박는다.
"""

from dataclasses import dataclass
from uuid import uuid4

from app.shared.retrieval import (
    keyword_match,
    like_pattern,
    reciprocal_rank_fusion,
    vector_literal,
)


def test_like_pattern_escapes_wildcards() -> None:
    assert like_pattern("100%") == "%100\\%%"
    assert like_pattern("a_b") == "%a\\_b%"
    assert like_pattern("back\\slash") == "%back\\\\slash%"


def test_vector_literal_serializes_pgvector_text_form() -> None:
    assert vector_literal([0.1, 0.2, 0.3]) == "[0.1,0.2,0.3]"


def test_keyword_match_uses_substring_not_token_equality() -> None:
    # 'simple' tsvector 토큰 동일성은 조사 붙은 한국어("민수와")에서 표제어("민수")가 0건 —
    # WHERE 는 단어별 ILIKE substring, 랭킹만 ts_rank_cd(@@ 매칭 아님).
    km = keyword_match("haystack", "민수 홍대")
    assert km.clauses == ["haystack ILIKE :kw0", "haystack ILIKE :kw1"]
    assert km.params["kw0"] == "%민수%" and km.params["kw1"] == "%홍대%"
    assert km.params["q"] == "민수 홍대"
    assert "ts_rank_cd" in km.rank_sql and "plainto_tsquery('simple', :q)" in km.rank_sql
    assert "@@" not in km.rank_sql


def test_keyword_match_caps_keywords() -> None:
    km = keyword_match("h", "a b c d e f g", max_keywords=5)
    assert len(km.clauses) == 5  # 6번째 이후는 노이즈라 버린다


def test_keyword_match_empty_query_yields_no_clauses() -> None:
    # 공백 쿼리 → ILIKE 절 없음. 호출부가 0건으로 처리한다.
    km = keyword_match("h", "   ")
    assert km.clauses == []
    assert km.params == {"q": "   "}


@dataclass
class _Item:
    id: object
    score: float


def test_rrf_accumulates_score_across_lists() -> None:
    a, b, c = _Item(uuid4(), 0.0), _Item(uuid4(), 0.0), _Item(uuid4(), 0.0)
    # b 는 두 리스트 상위에 모두 들어 점수 누적 → 최상위.
    fused = reciprocal_rank_fusion([[a, b], [b, c]], id_of=lambda i: i.id)
    ordered = [item for item, _ in fused]
    assert ordered[0] is b
    assert set(id(i) for i in ordered) == {id(a), id(b), id(c)}  # dedup


def test_rrf_defaults_to_first_occurrence_representative() -> None:
    key = uuid4()
    first, second = _Item(key, 1.0), _Item(key, 9.0)
    fused = reciprocal_rank_fusion([[first], [second]], id_of=lambda i: i.id)
    assert len(fused) == 1
    assert fused[0][0] is first  # 첫 출현본 보존


def test_rrf_prefer_selects_representative() -> None:
    key = uuid4()
    lo, hi = _Item(key, 1.0), _Item(key, 9.0)
    fused = reciprocal_rank_fusion(
        [[lo], [hi]],
        id_of=lambda i: i.id,
        prefer=lambda cur, cand: cand if cand.score > cur.score else cur,
    )
    assert fused[0][0] is hi  # 원점수가 더 높은 후보를 대표로
