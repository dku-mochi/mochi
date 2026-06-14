"""Vertex AI Gemini 채팅 어댑터 — function-calling AUTO + 텍스트 스트리밍.

기존 ``GeminiAgentClient`` 는 finalize 전용(mode=ANY, 스트림 없음)이라 재사용 불가 —
같은 공유 클라이언트 패턴(``genai.Client`` lru_cache)만 가져오고 호출 형태를 채팅용으로 바꾼다:

- ``generate_content_stream`` — 답변 텍스트를 글자 단위로 SSE 에 흘리기 위해.
- ``tool_config`` — 턴 첫 라운드는 mode=ANY(함수 호출 강제, ``force_tool``), 이후 라운드는
  AUTO. AUTO 단독은 긴 대화에서 툴콜을 누락하는 알려진 거동이 있다 (chat@v10).
- 모델은 ``gemini_chat_model`` (기본 flash-lite — lab 벤치 후 .env 로 상향 가능, 코드 불변).
- ``thinking_budget=512`` — 분석 루프(0)와 달리 채팅은 정보 단위 분해·툴 선택 판단이 승부처라
  최소 budget 을 켠다 (chat@v9). thought_signature 는 함수콜 part 에 이미 왕복 배선돼 있다.
"""

from collections.abc import AsyncIterator
from functools import lru_cache
from typing import Any, cast

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.conversations.domain.ports import ChatLLMChunk, ChatLLMClient, ChatTool
from app.shared.llm_usage import extract_token_usage

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

    지원 형태: {"role","text"} / {"function_calls":[{name,args,thought_signature?},...]} /
    {"function_responses":[{name,response},...]}. 같은 라운드의 병렬 콜은 반드시 하나의
    model/user Content 에 다중 part 로 담는다 — thinking 활성 시 thought_signature 가
    라운드 첫 part 에만 와서, 콜 단위로 쪼개면 Gemini 시그니처 검증(400)에 걸린다.
    text part 는 ``images``(gs:// URI, mime) 목록을 동반할 수 있다 — view_item_image 첨부.
    """
    contents: list[types.Content] = []
    for part in parts:
        if "function_calls" in part:
            contents.append(
                types.Content(
                    role="model",
                    parts=[
                        types.Part(
                            function_call=types.FunctionCall(name=fc["name"], args=fc.get("args", {})),
                            thought_signature=fc.get("thought_signature"),
                        )
                        for fc in part["function_calls"]
                    ],
                )
            )
        elif "function_responses" in part:
            contents.append(
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_function_response(
                            name=fr["name"], response=fr.get("response", {})
                        )
                        for fr in part["function_responses"]
                    ],
                )
            )
        else:
            content_parts: list[types.Part] = [types.Part(text=part.get("text", ""))]
            # 멀티모달 입력: gs:// 이미지를 같은 user turn 에 첨부 (Gemini 가 직접 read) — agent 와 동형.
            for uri, mime in part.get("images", []):
                content_parts.append(types.Part.from_uri(file_uri=uri, mime_type=mime))
            contents.append(types.Content(role=part.get("role", "user"), parts=content_parts))
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
        force_tool: bool = False,
    ) -> AsyncIterator[ChatLLMChunk]:
        decls = [
            types.FunctionDeclaration(name=t.name, description=t.description, parameters=t.parameters)
            for t in tools
        ]
        cfg = types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.6,
            # thinking 토큰은 max_output_tokens 에 포함되므로 budget 만큼 상한을 같이 올린다.
            max_output_tokens=2048,
            thinking_config=types.ThinkingConfig(thinking_budget=512),
            tools=[types.Tool(function_declarations=decls)] if decls else None,
            tool_config=(
                types.ToolConfig(
                    function_calling_config=types.FunctionCallingConfig(
                        # ANY = 이 라운드는 함수 호출 강제 — AUTO 의 툴콜 누락(긴 대화에서 악화)을
                        # 턴 첫 라운드에 한해 기계로 차단한다. ports.ChatLLMClient 참고.
                        mode="ANY" if force_tool else "AUTO"
                    )
                )
                if decls
                else None
            ),
        )
        stream = await _shared_client().aio.models.generate_content_stream(
            model=self._model, contents=cast(types.ContentListUnion, _to_contents(contents)), config=cfg
        )
        tokens_in = 0
        tokens_out = 0
        async for chunk in stream:
            chunk_in, chunk_out = extract_token_usage(chunk)
            # usage_metadata 는 마지막 청크에 누적 총합으로 실린다 — non-zero 면 갱신(덮어쓰기).
            if chunk_in or chunk_out:
                tokens_in, tokens_out = chunk_in, chunk_out
            for cand in getattr(chunk, "candidates", None) or []:
                finish = getattr(cand, "finish_reason", None)
                if finish is not None and "STOP" not in str(finish):
                    # ANY 라운드가 유효 함수콜 없이 끝나는 실패(MALFORMED_FUNCTION_CALL 등)를
                    # 식별 가능하게 — generic '빈 답변' 폴백만으로는 실기기 디버깅이 안 된다.
                    logger.warning(
                        "chat.llm.abnormal_finish",
                        model=self._model,
                        finish_reason=str(finish),
                    )
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
                    elif getattr(part, "text", None) and not getattr(part, "thought", False):
                        # thought=True part 는 모델의 reasoning 요약 — include_thoughts 기본
                        # false 라 현재는 안 오지만, 새면 채팅 버블로 노출되므로 가드.
                        yield ChatLLMChunk(text_delta=part.text)
        # 스트림 종료 — 이 라운드의 토큰 사용량만 담은 청크를 마지막에 한 번 흘린다(run 루프가 누적).
        if tokens_in or tokens_out:
            yield ChatLLMChunk(tokens_in=tokens_in, tokens_out=tokens_out, model=self._model)
