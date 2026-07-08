from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import StrEnum
from typing import Any
from uuid import UUID

from pydantic import BaseModel


class ToolName(StrEnum):
    MULTIMODAL_ANALYZE = "multimodalAnalyze"
    OCR_FALLBACK = "ocrFallback"
    WEB_FETCH = "webFetch"
    WEB_SEARCH = "webSearch"
    PLATFORM_CONTEXT = "platformContext"
    RESOURCE_FINDER = "findReferenceUrls"
    SEARCH_PLACE_GEO = "searchPlaceGeo"
    RECOVER_YOUTUBE_URL = "recoverYoutubeUrl"
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


@dataclass(frozen=True, slots=True)
class ToolContext:
    """owner-scoped tool 이 실행 시점에 받는 호출 컨텍스트 — 현재 분석 중인 item·owner.

    owner_id 는 LLM args 가 아니라 orchestrator 가 주입한다(환각·주입으로 cross-tenant
    누설이 생기지 않게 — 검색 스코프는 모델이 정할 값이 아니다).
    """

    owner_id: UUID
    mochi_item_id: UUID


class ContextAwareTool[TIn: BaseModel, TOut: BaseModel](Tool[TIn, TOut]):
    """호출 컨텍스트(owner_id 등)가 필요한 tool. orchestrator 가 ``run_with_context`` 로 부른다.

    기본 ``run`` 은 막아 둔다 — 컨텍스트 없이 부르면 owner 스코프가 빠진 검색이 되기 때문.
    """

    @abstractmethod
    async def run_with_context(self, payload: TIn, *, context: ToolContext) -> tuple[TOut, ToolUsage]:
        raise NotImplementedError

    async def run(self, payload: TIn) -> tuple[TOut, ToolUsage]:
        raise RuntimeError(f"{self.name} requires ToolContext — invoke via orchestrator._run_tool")


class ToolExecutionError(Exception):
    def __init__(self, tool: ToolName, message: str, *, transient: bool = False):
        super().__init__(message)
        self.tool = tool
        self.message = message
        self.transient = transient
