"""Reciprocal Rank Fusion — BM25/벡터 점수를 비교 가능하게 합치는 표준 방법.

k=60이 IR 문헌의 표준 default. ``rrf_k_constant`` 로 settings에서 조정 가능.
"""

from collections import defaultdict

from app.modules.search.domain.entities import Citation


def reciprocal_rank_fusion(
    *lists: list[Citation],
    k: int = 60,
) -> list[Citation]:
    score: dict[str, float] = defaultdict(float)
    snippet: dict[str, Citation] = {}
    for ranking in lists:
        for rank, citation in enumerate(ranking, start=1):
            key = str(citation.mochi_item_id)
            score[key] += 1.0 / (k + rank)
            # 더 높은 원점수의 snippet을 보관
            if key not in snippet or citation.score > snippet[key].score:
                snippet[key] = citation

    merged = [
        Citation(mochi_item_id=c.mochi_item_id, snippet=c.snippet, score=score[str(c.mochi_item_id)])
        for c in snippet.values()
    ]
    merged.sort(key=lambda c: c.score, reverse=True)
    return merged
