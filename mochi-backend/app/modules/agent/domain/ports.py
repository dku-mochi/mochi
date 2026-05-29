from collections.abc import AsyncIterator
from typing import Any, Protocol

from pydantic import BaseModel

from app.modules.agent.domain.tools import Tool, ToolName


class LLMResponseChunk(BaseModel):
    text_delta: str | None = None
    tool_to_call: ToolName | None = None
    tool_arguments: dict[str, Any] | None = None
    final_payload: dict[str, Any] | None = None
    # Gemini 3 는 멀티턴에서 직전 functionCall part 에 thought_signature 를 echo back 해야
    # 한다 (thinking_budget=0 이어도 필수). 도구 호출 chunk 가 이를 실어 orchestrator 가
    # 다음 turn 대화에 되돌려준다.
    thought_signature: bytes | None = None


class LLMClient(Protocol):
    """Gemini agentic client 추상화 — 테스트는 fake 구현을 주입.

    ``stream`` 은 async generator 를 반환한다 (``def`` 로 선언 — async generator 함수는
    ``def ... -> AsyncIterator`` 시그니처를 만족한다).
    """

    def stream(
        self,
        *,
        system_prompt: str,
        user_parts: list[dict[str, Any]],
        tools: list[Tool[Any, Any]],
        thought_signature: str | None,
    ) -> AsyncIterator[LLMResponseChunk]: ...


class ToolRegistry(Protocol):
    def get(self, name: ToolName) -> Tool[Any, Any]: ...
    def all(self) -> list[Tool[Any, Any]]: ...
