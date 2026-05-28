from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

from pydantic import BaseModel


class ToolName(StrEnum):
    MULTIMODAL_ANALYZE = "multimodalAnalyze"
    OCR_FALLBACK = "ocrFallback"
    WEB_FETCH = "webFetch"
    EMBED = "embed"
    HYBRID_SEARCH = "hybridSearch"
    CALENDAR_SYNC = "calendarSync"


@dataclass(slots=True)
class ToolUsage:
    tokens_in: int = 0
    tokens_out: int = 0
    latency_ms: int = 0


class Tool[TIn: BaseModel, TOut: BaseModel](ABC):
    """타입 안전 tool 추상 베이스. Python 3.12 PEP 695 제네릭 문법.

    Gemini function-calling 스키마는 ``TIn`` 모델의 JSON Schema 에서 자동 생성된다.
    """

    name: ToolName
    input_model: type[TIn]
    output_model: type[TOut]

    @abstractmethod
    async def run(self, payload: TIn) -> tuple[TOut, ToolUsage]:
        raise NotImplementedError

    def schema(self) -> dict[str, Any]:
        return self.input_model.model_json_schema()


class ToolExecutionError(Exception):
    def __init__(self, tool: ToolName, message: str, *, transient: bool = False):
        super().__init__(message)
        self.tool = tool
        self.message = message
        self.transient = transient
