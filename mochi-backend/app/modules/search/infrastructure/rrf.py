"""Reciprocal Rank Fusion (Citation 어댑터) — ``/search`` 파이프라인이 쓰는 Citation 타입
래퍼. 융합 로직 자체는 공유 커널 ``app.shared.retrieval`` 이 단일 원천이다(채팅/분석 agent
``search_items`` 와 같은 구현).

k=60 이 IR 문헌 표준 default. ``rrf_k_constant`` 로 settings 에서 조정 가능.
"""

from app.modules.search.domain.entities import Citation
from app.shared.retrieval import RRF_K
from app.shared.retrieval import reciprocal_rank_fusion as _fuse


def reciprocal_rank_fusion(*lists: list[Citation], k: int = RRF_K) -> list[Citation]:
    fused = _fuse(
        lists,
        id_of=lambda c: c.mochi_item_id,
        k=k,
        # 대표 snippet 은 원점수가 더 높은 후보를 보존 (기존 동작).
        prefer=lambda cur, cand: cand if cand.score > cur.score else cur,
    )
    return [Citation(mochi_item_id=c.mochi_item_id, snippet=c.snippet, score=score) for c, score in fused]
