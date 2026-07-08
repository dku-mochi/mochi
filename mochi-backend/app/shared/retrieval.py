"""Hybrid retrieval kernel — 두 검색 경로(``/search`` RAG · 채팅/분석 agent ``search_items``)가
공유하는 랭킹 프리미티브.

한 곳에 두는 이유는 드리프트 방지다: 한국어 조사 회귀(2026-06-10)를 채팅 툴에서 ILIKE 로
고쳤을 때 ``/search`` 의 ``bm25`` 는 tsvector ``@@`` 로 남아 같은 버그를 유지했다. 키워드
매칭식·RRF·vector 직렬화·상수를 이 커널로 모아 두 경로가 문자 그대로 한 구현을 쓴다.

경로별로 정당하게 다른 것은 여기서 강제하지 않는다 — 호출부가 haystack·필터·id 추출을 주입한다:
- 출력 계약: RAG 답변 합성(A) vs 아이템 리스트(B)
- 필터 모델: ``SearchScope`` 단일(A) vs 구조화 필터(intent·2 시간축)(B)
- query 수: 단일(A) vs 다중 융합(B)
- haystack 컬럼: summary+text(A) vs summary+text+user_memo(B)
"""

from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from typing import Any

#: RRF(Reciprocal Rank Fusion) 상수 — IR 문헌 표준 default. rank 차이를 부드럽게 흡수한다.
#: ``/search`` 는 ``settings.rrf_k_constant`` 로 override 가능(운영 튜닝), 그 default 가 이 값이다.
RRF_K = 60

#: 키워드당 substring 매칭 상한 — 그 이상은 노이즈(plainto 의 AND 의미는 유지).
MAX_KEYWORDS = 5


def like_pattern(word: str) -> str:
    """ILIKE substring 패턴 — ``%``/``_``/``\\`` 를 이스케이프해 리터럴로 매칭한다."""
    escaped = word.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def vector_literal(embedding: Sequence[float]) -> str:
    """pgvector text-form 직렬화 — ``CAST(:param AS vector)`` 에 문자열로 바인드한다."""
    return "[" + ",".join(map(str, embedding)) + "]"


@dataclass(slots=True)
class KeywordMatch:
    """단어별 substring(ILIKE AND) 예측자 + BM25 근사 랭킹식.

    호출부는 ``clauses`` 를 자신의 WHERE 에 AND 로 붙이고, ``params`` 를 바인드하고,
    ``rank_sql`` 을 ORDER BY 에 쓴다. ``clauses`` 가 비면(공백 쿼리) 호출부가 0건 처리한다.
    """

    clauses: list[str]
    params: dict[str, Any]
    rank_sql: str


def keyword_match(haystack_sql: str, query: str, *, max_keywords: int = MAX_KEYWORDS) -> KeywordMatch:
    """단어별 ILIKE substring 매칭 — 'simple' tsvector 토큰 동일성이 조사 붙은 한국어
    ("민수와" vs "민수")를 0건 만드는 회귀(2026-06-10)의 보험. WHERE 는 substring, 랭킹만
    ``ts_rank_cd`` 로 근사한다.

    ``haystack_sql`` 은 검색 대상 텍스트 SQL 식(테이블 alias 포함 여부는 호출부 컨벤션).
    바인드 이름은 랭킹 쿼리 ``:q`` + 키워드 ``:kw{idx}`` — 호출부 base params 와 겹치지 않게 쓴다.
    """
    clauses: list[str] = []
    params: dict[str, Any] = {"q": query}
    for idx, word in enumerate(query.split()[:max_keywords]):
        clauses.append(f"{haystack_sql} ILIKE :kw{idx}")
        params[f"kw{idx}"] = like_pattern(word)
    rank_sql = f"ts_rank_cd(to_tsvector('simple', {haystack_sql}), plainto_tsquery('simple', :q))"
    return KeywordMatch(clauses=clauses, params=params, rank_sql=rank_sql)


def reciprocal_rank_fusion[T](
    ranked_lists: Iterable[Sequence[T]],
    *,
    id_of: Callable[[T], Any],
    k: int = RRF_K,
    prefer: Callable[[T, T], T] | None = None,
) -> list[tuple[T, float]]:
    """여러 순위 리스트를 id별 Σ 1/(k+rank) 로 합쳐 융합 점수 내림차순. IR 표준 RRF.

    같은 id 가 여러 리스트 상위에 들수록 점수가 누적돼 위로 온다. 대표 객체는 기본적으로
    첫 출현본을 보존하고, ``prefer(current, candidate) -> keep`` 가 주어지면 그걸로 고른다
    (예: 원점수가 더 높은 snippet 보존). ``(대표객체, 융합점수)`` 를 순서대로 돌려준다.
    """
    scores: dict[Any, float] = {}
    rep: dict[Any, T] = {}
    for ranked in ranked_lists:
        for rank, item in enumerate(ranked, start=1):
            key = id_of(item)
            scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank)
            if key not in rep:
                rep[key] = item
            elif prefer is not None:
                rep[key] = prefer(rep[key], item)
    return [(rep[key], scores[key]) for key in sorted(scores, key=lambda key_: scores[key_], reverse=True)]
