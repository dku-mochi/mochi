from dataclasses import dataclass, field
from datetime import datetime
from uuid import UUID, uuid4

from app.modules.agent.domain.states import AgentNode
from app.modules.agent.domain.tools import ToolName


@dataclass(slots=True)
class ToolCall:
    name: ToolName
    input_digest: str
    output_digest: str | None
    tokens_in: int
    tokens_out: int
    latency_ms: int
    succeeded: bool


@dataclass(slots=True)
class AgentRun:
    mochi_item_id: UUID
    id: UUID = field(default_factory=uuid4)
    current_node: AgentNode = AgentNode.INGESTED
    tool_calls: list[ToolCall] = field(default_factory=list)
    total_tokens: int = 0
    total_latency_ms: int = 0
    started_at: datetime = field(default_factory=datetime.utcnow)
    ended_at: datetime | None = None
    failure_reason: str | None = None

    def advance(self, node: AgentNode) -> None:
        self.current_node = node

    def record(self, call: ToolCall) -> None:
        self.tool_calls.append(call)
        self.total_tokens += call.tokens_in + call.tokens_out
        self.total_latency_ms += call.latency_ms

    def fail(self, reason: str) -> None:
        self.failure_reason = reason
        self.current_node = AgentNode.FAILED
        self.ended_at = datetime.utcnow()

    def succeed(self) -> None:
        self.ended_at = datetime.utcnow()
