from collections.abc import AsyncIterator
from typing import Protocol

from pydantic import BaseModel

from app.modules.agent.domain.tools import Tool, ToolName


class LLMResponseChunk(BaseModel):
    text_delta: str | None = None
    tool_to_call: ToolName | None = None
    tool_arguments: dict | None = None
    final_payload: dict | None = None


class LLMClient(Protocol):
    """Gemini multimodal client 추상화 — 테스트는 fake 구현을 주입."""

    async def stream(
        self,
        *,
        system_prompt: str,
        user_parts: list[dict],
        tools: list[Tool],
        thought_signature: str | None,
    ) -> AsyncIterator[LLMResponseChunk]: ...


class ToolRegistry(Protocol):
    def get(self, name: ToolName) -> Tool: ...
    def all(self) -> list[Tool]: ...
