"""채팅 run 이 흘리는 이벤트 — SSE wire format 과 1:1 (pure).

iOS `ChatStreamEvent` 와 동형. `done`/`error` 가 스트림 종료 신호다.
"""

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ChatEvent:
    kind: str
    payload: dict[str, Any]


MESSAGE_DELTA = "message_delta"
TOOL_STARTED = "tool_started"
TOOL_FINISHED = "tool_finished"
CITATION = "citation"
PROPOSAL = "proposal"
DONE = "done"
ERROR = "error"
