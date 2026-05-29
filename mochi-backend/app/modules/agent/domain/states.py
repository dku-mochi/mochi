from enum import StrEnum


class AgentNode(StrEnum):
    """Agent state graph 노드. iOS `CoreDomain.AgentNode` 와 동일."""

    INGESTED = "ingested"
    NORMALIZED = "normalized"
    ANALYZED = "analyzed"
    ROUTED = "routed"
    PERSISTED = "persisted"
    INDEXED = "indexed"
    SYNCED = "synced"
    FAILED = "failed"


# 정상 선형 경로 (실패 시 어디서든 FAILED 로 분기 가능).
HAPPY_PATH: list[AgentNode] = [
    AgentNode.INGESTED,
    AgentNode.NORMALIZED,
    AgentNode.ANALYZED,
    AgentNode.ROUTED,
    AgentNode.PERSISTED,
    AgentNode.INDEXED,
    AgentNode.SYNCED,
]
