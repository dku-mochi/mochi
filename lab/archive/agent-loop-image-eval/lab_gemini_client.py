"""lab 전용 LLMClient — 로컬 이미지를 inline bytes로 처리 (GCS 불필요).

프로덕션 GeminiAgentClient 와 동일하되 _to_contents() 에서
gs:// URI 대신 로컬 파일 경로를 Part.from_bytes() 로 변환한다.

프로덕션 반영 방법은 CHANGES.md 참고.
"""
import asyncio
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import structlog
from google.genai import types

from app.core.config import get_settings
from app.modules.agent.domain.ports import LLMClient, LLMResponseChunk
from app.modules.agent.domain.tools import Tool, ToolName
from app.modules.agent.infrastructure.gemini_agent_client import (
    _FINALIZE,
    _call,
    _extract_function_call,
    _function_declarations,
)

logger = structlog.get_logger(__name__)


def _to_contents_local(user_parts: list[dict[str, Any]]) -> list[types.Content]:
    """로컬 파일 경로를 inline bytes로 변환 (gs:// 는 from_uri 유지)."""
    contents: list[types.Content] = []
    for part in user_parts:
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
                        types.Part.from_function_response(name=fr["name"], response=fr.get("response", {}))
                    ],
                )
            )
        else:
            content_parts: list[types.Part] = [types.Part(text=part.get("text", ""))]
            for path_or_uri, mime in part.get("images", []):
                if path_or_uri.startswith("gs://"):
                    content_parts.append(types.Part.from_uri(file_uri=path_or_uri, mime_type=mime))
                else:
                    content_parts.append(
                        types.Part.from_bytes(data=Path(path_or_uri).read_bytes(), mime_type=mime)
                    )
            contents.append(types.Content(role=part.get("role", "user"), parts=content_parts))
    return contents


class LabGeminiClient(LLMClient):
    """프로덕션 GeminiAgentClient 와 동일하나 로컬 이미지 경로를 지원."""

    def __init__(self, model: str | None = None, timeout_seconds: float | None = None):
        settings = get_settings()
        self._model = model or settings.gemini_agent_model
        self._timeout = timeout_seconds or settings.agent_step_timeout_seconds

    async def stream(
        self,
        *,
        system_prompt: str,
        user_parts: list[dict[str, Any]],
        tools: list[Tool[Any, Any]],
        thought_signature: str | None,
    ) -> AsyncIterator[LLMResponseChunk]:
        decls = _function_declarations(tools)
        contents = _to_contents_local(user_parts)
        resp = await asyncio.wait_for(
            _call(
                system_prompt=system_prompt,
                contents=contents,
                decls=decls,
                model=self._model,
            ),
            timeout=self._timeout,
        )
        fc = _extract_function_call(resp)
        if fc is None:
            logger.warning("lab.llm.no_function_call", model=self._model)
            text = getattr(resp, "text", None)
            yield LLMResponseChunk(text_delta=text or "")
            return
        name, args, signature = fc
        if name == _FINALIZE:
            args["model_version"] = self._model
            yield LLMResponseChunk(final_payload=args)
        else:
            yield LLMResponseChunk(
                tool_to_call=ToolName(name), tool_arguments=args, thought_signature=signature
            )
