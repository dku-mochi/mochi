from uuid import uuid4

from app.modules.search.domain.entities import Citation
from app.modules.search.infrastructure.rrf import reciprocal_rank_fusion


def _c(score: float) -> Citation:
    return Citation(capture_id=uuid4(), snippet="...", score=score)


def test_rrf_higher_rank_in_either_list_dominates() -> None:
    a = _c(score=10.0)
    b = _c(score=8.0)
    c = _c(score=6.0)
    bm25 = [a, b, c]
    vec = [b, a, c]

    merged = reciprocal_rank_fusion(bm25, vec, k=60)
    # rank-1 한 번 + rank-2 한 번 = a, b 동일하지만 a가 bm25에서 1위라 안정 정렬 후 첫번째.
    assert merged[0].capture_id in {a.capture_id, b.capture_id}
    assert merged[-1].capture_id == c.capture_id
