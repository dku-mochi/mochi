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
