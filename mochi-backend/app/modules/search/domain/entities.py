from dataclasses import dataclass, field
from enum import StrEnum
from uuid import UUID


class SearchScope(StrEnum):
    ALL = "all"
    SCHEDULE = "schedule"
    TODO = "todo"
    KNOWLEDGE = "knowledge"
    MEMO = "memo"


@dataclass(slots=True)
class SearchQuery:
    text: str
    scope: SearchScope = SearchScope.ALL
    owner_id: UUID | None = None
    bm25_k: int = 80
    vector_k: int = 80
    top_k: int = 10


@dataclass(slots=True)
class Citation:
    mochi_item_id: UUID
    snippet: str
    score: float


@dataclass(slots=True)
class SearchResult:
    answer: str
    citations: list[Citation] = field(default_factory=list)
    total_tokens: int = 0
    agent_run_id: UUID | None = None


class SimilarReasonKind(StrEnum):
    """"왜 비슷한지" 연결 이유 신호 — 서버 계산 enum. 한국어 카피는 iOS 가 매핑한다
    (카피 변경이 ⓪ openapi 폭포를 안 타도록). 1차는 기본 컬럼만 쓰는 3종 — 엔티티 겹침은
    후속(`DOMAIN_DESIGN.md` §10.5)."""

    SHARED_SOURCE = "sharedSource"  # 같은 출처 URL
    SAME_INTENT = "sameIntent"  # intent_type 교집합
    CLOSE_IN_TIME = "closeInTime"  # captured_at 근접


@dataclass(slots=True)
class SimilarReason:
    kind: SimilarReasonKind
    value: str | None = None  # sameIntent 의 교집합 intent_type 등 보조값


@dataclass(slots=True)
class SimilarItem:
    """한 MochiItem 의 cosine 이웃 1건 — 저장 안 하는 read-time projection (§10.5)."""

    mochi_item_id: UUID
    score: float
    reasons: list[SimilarReason] = field(default_factory=list)
