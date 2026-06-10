"""web_fetch — 외부 URL 본문 채팅 툴 (read-only).

기존 agent ``WebFetchTool``(SSRF·redirect 재검증·사이즈·MIME 가드)을 **무수정 재사용**
한다 — 모듈 경계상 타 모듈 infrastructure 직접 import 가 금지라
``agent.application.tool_factories``(허용 진입점) 경유로 인스턴스를 받는다.
채팅 컨텍스트 예산(~16k tokens, journal 2026-06-10)에 맞춰 HTML 텍스트화와
truncation 만 더한다. web_search 결과뿐 아니라 기록에 저장된 링크 읽기에도 쓰여
키 없이 항상 등록된다.
"""

import html as html_module
import re
from typing import Any
from uuid import UUID

from pydantic import ValidationError

from app.modules.agent.domain.tools import Tool, ToolExecutionError
from app.modules.conversations.domain.ports import ChatToolResult

TEXT_CHARS = 4000

_SCRIPT_STYLE = re.compile(r"<(script|style)\b[^>]*>.*?</\1\s*>", re.IGNORECASE | re.DOTALL)
_TAG = re.compile(r"<[^>]+>")


def _readable_text(raw: str) -> str:
    """LLM 입력용 텍스트화 — script/style 본문 제거 → 태그 제거 → entity 해제 → 공백 접기."""
    text = _SCRIPT_STYLE.sub(" ", raw)
    text = _TAG.sub(" ", text)
    return re.sub(r"\s+", " ", html_module.unescape(text)).strip()


_PARAMETERS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "url": {
            "type": "string",
            "description": (
                "Absolute http(s) URL — from a web_search result or a url stored in the "
                "user's records."
            ),
        },
    },
    "required": ["url"],
}


class WebFetchChatTool:
    name = "web_fetch"
    label = "페이지를 읽고 있어요"
    description = (
        "Fetch one web page and return its readable text (truncated). Use to read a "
        "web_search result or a link saved in the user's records before answering from it."
    )
    parameters = _PARAMETERS

    def __init__(self, fetch_tool: Tool[Any, Any]):
        self._fetch = fetch_tool

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        try:
            payload = self._fetch.input_model(url=args.get("url"))
        except ValidationError:
            return ChatToolResult(
                payload={"error": "invalid url — must be an absolute http(s) URL"},
                summary="페이지를 못 열었어요",
            )
        try:
            output, _usage = await self._fetch.run(payload)
        except ToolExecutionError as exc:
            # 가드 차단(SSRF·MIME·사이즈)·HTTP 실패 — 사유를 돌려 모델이 다른 출처로 우회하게.
            return ChatToolResult(payload={"error": exc.message}, summary="페이지를 못 열었어요")

        text: str = output.text
        if output.mime_type.startswith(("text/html", "application/xhtml+xml")):
            text = _readable_text(text)
        return ChatToolResult(
            payload={
                "url": output.final_url,
                "status_code": output.status_code,
                "text": text[:TEXT_CHARS],
                "truncated": len(text) > TEXT_CHARS,
            },
            summary="페이지를 읽었어요",
            compact={"url": output.final_url},
        )
