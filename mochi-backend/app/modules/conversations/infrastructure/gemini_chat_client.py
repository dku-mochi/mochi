"""Vertex AI Gemini 채팅 어댑터 — function-calling AUTO + 텍스트 스트리밍.

기존 ``GeminiAgentClient`` 는 finalize 전용(mode=ANY, 스트림 없음)이라 재사용 불가 —
같은 공유 클라이언트 패턴(``genai.Client`` lru_cache)만 가져오고 호출 형태를 채팅용으로 바꾼다:

- ``generate_content_stream`` — 답변 텍스트를 글자 단위로 SSE 에 흘리기 위해.
- ``tool_config`` mode=AUTO — 모델이 툴을 부를지 답변할지 스스로 결정 (분석 루프의 ANY 와 다름).
- 모델은 ``gemini_chat_model`` (기본 flash-lite — lab 벤치 후 .env 로 상향 가능, 코드 불변).
"""

from collections.abc import AsyncIterator
from functools import lru_cache
from typing import Any

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.conversations.domain.ports import ChatLLMChunk, ChatLLMClient, ChatTool

logger = structlog.get_logger(__name__)


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _to_contents(parts: list[dict[str, Any]]) -> list[types.Content]:
    """정규화 대화(list[dict])를 genai Content 로 변환 — agent ``_to_contents`` 와 동형.

    지원 형태: {"role","text"} / {"function_call":{name,args}} / {"function_response":{name,response}}.
    """
    contents: list[types.Content] = []
    for part in parts:
        if "function_call" in part:
            fc = part["function_call"]
            contents.append(
                types.Content(
                    role="model",
                    parts=[
                        types.Part(
                            function_call=types.FunctionCall(name=fc["name"], args=fc.get("args", {})),
                            thought_signature=part.get("thought_signature"),
                        )
                    ],
                )
            )
        elif "function_response" in part:
            fr = part["function_response"]
            contents.append(
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_function_response(
                            name=fr["name"], response=fr.get("response", {})
                        )
                    ],
                )
            )
        else:
            contents.append(
                types.Content(role=part.get("role", "user"), parts=[types.Part(text=part.get("text", ""))])
            )
    return contents


class GeminiChatClient(ChatLLMClient):
    def __init__(self, model: str | None = None):
        self._model = model or get_settings().gemini_chat_model

    async def stream(
        self,
        *,
        system_prompt: str,
        contents: list[dict[str, Any]],
        tools: list[ChatTool],
    ) -> AsyncIterator[ChatLLMChunk]:
        decls = [
            types.FunctionDeclaration(name=t.name, description=t.description, parameters=t.parameters)
            for t in tools
        ]
        cfg = types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.6,
            max_output_tokens=1024,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
            tools=[types.Tool(function_declarations=decls)] if decls else None,
            tool_config=(
                types.ToolConfig(function_calling_config=types.FunctionCallingConfig(mode="AUTO"))
                if decls
                else None
            ),
        )
        stream = await _shared_client().aio.models.generate_content_stream(
            model=self._model, contents=_to_contents(contents), config=cfg
        )
        async for chunk in stream:
            for cand in getattr(chunk, "candidates", None) or []:
                content = getattr(cand, "content", None)
                for part in (getattr(content, "parts", None) or []) if content else []:
                    fc = getattr(part, "function_call", None)
                    if fc is not None and getattr(fc, "name", None):
                        logger.info(
                            "chat.llm.function_call", model=self._model, function_name=fc.name
                        )
                        yield ChatLLMChunk(
                            tool_call=(fc.name, dict(fc.args or {})),
                            thought_signature=getattr(part, "thought_signature", None),
                        )
                    elif getattr(part, "text", None):
                        yield ChatLLMChunk(text_delta=part.text)
