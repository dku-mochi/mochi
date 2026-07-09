"""Vertex AI Gemini 기반 agentic ``LLMClient`` 어댑터 (Arch2).

호출 패턴:
- 공유 ``genai.Client(vertexai=True)`` (lru_cache, 프로세스당 1개)
- SDK native async (``.aio.models.generate_content``) + ``asyncio.wait_for(step_timeout)`` — 타임아웃 시 실제 취소
- 비용 최우선: flash-lite + ``thinking_budget=0`` (thought-signature 불필요 → 단순)

함수 호출 루프 매핑:
- LLM 이 능동적으로 부를 도구는 ``platformContext``/``webFetch`` (URL 그라운딩).
- 종료는 별도 함수 ``finalizeAnalysis`` — 모델이 이를 호출하면 그 args 가 구조화 분석
  (``MultimodalAnalyzeOutput`` 모양)이다 → ``LLMResponseChunk.final_payload``.
- ``tool_config`` mode=ANY 로 매 turn 함수 호출을 강제 → 루프가 항상 진행한다.

orchestrator 가 turn 단위로 ``stream`` 을 호출하며, 전체 대화(``user_parts``)를 매 turn
넘긴다. 본 어댑터는 google-genai 특이사항을 캡슐화하고 orchestrator 는 순수하게 유지된다.
"""

import asyncio
from collections.abc import AsyncIterator
from functools import lru_cache
from typing import Any, cast

import structlog
from google import genai
from google.genai import types

from app.core.config import get_settings
from app.modules.agent.domain.ports import LLMClient, LLMResponseChunk
from app.modules.agent.domain.tools import Tool, ToolName
from app.shared.llm_usage import extract_token_usage

logger = structlog.get_logger(__name__)

_FINALIZE = "finalizeAnalysis"
_INTENT_ENUM = ["schedule", "todo", "knowledge", "memo"]

_PAYLOAD_PROPS: dict[str, Any] = {
    "title": {"type": "string"},
    "date": {
        "type": "string",
        "description": (
            "Event start date, ISO `YYYY-MM-DD` (e.g. 2026-06-26). Resolve a partial or relative "
            "date (bare month/day, weekday, '다음 주') against the current time in the user message "
            "and infer the year — that resolution is required, not invention. Fill it whenever the "
            "capture identifies a day."
        ),
    },
    "time": {
        "type": "string",
        "description": "Start time, 24-hour `HH:MM` (e.g. 14:30). Omit if no clock time is given.",
    },
    "end_date": {
        "type": "string",
        "description": "End date of a multi-day event, ISO `YYYY-MM-DD` (date is the start). Omit for a single day.",
    },
    "end_time": {"type": "string", "description": "End time, 24-hour `HH:MM`. Omit if not shown."},
    "deadline": {
        "type": "string",
        "description": (
            "Todo due moment, ISO `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`. Compute a relative deadline "
            "('10분 뒤', '내일까지', '이번 주말') from the current time in the user message — that "
            "computation is required, not invention."
        ),
    },
    "person": {"type": "string"},
    "topic": {"type": "string"},
    "url": {"type": "string"},
    "note": {"type": "string"},
}

_FINALIZE_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "category": {"type": "string"},
        "needs_review": {"type": "boolean"},
        "intent_instances": {
            # 저장할 것만(곧 active). 같은 type 다중 허용 — 개수 가변(점수/대표/위계 폐기).
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "intent_type": {"type": "string", "enum": _INTENT_ENUM},
                    "payload": {"type": "object", "properties": _PAYLOAD_PROPS, "required": ["title"]},
                    "label": {"type": "string"},
                    "reasoning": {"type": "string"},
                },
                "required": ["intent_type", "payload", "label", "reasoning"],
            },
        },
        "review_options": {
            # needs_review=true 일 때 제시할 미확정 후보 (instance 아님 — 저장 안 함).
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "intent_type": {"type": "string", "enum": _INTENT_ENUM},
                    "label": {"type": "string"},
                    "reasoning": {"type": "string"},
                },
                "required": ["intent_type", "label", "reasoning"],
            },
        },
        "entities": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string"},
                    "value": {"type": "string"},
                },
                "required": ["kind", "value"],
            },
        },
        "importance": {"type": "integer"},
    },
    "required": ["summary", "category", "intent_instances", "needs_review"],
}

_WEBFETCH_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {"url": {"type": "string"}},
    "required": ["url"],
}

_PLATFORM_CONTEXT_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "url": {"type": "string"},
        "platform": {
            "type": "string",
            "enum": ["auto", "youtube", "x", "instagram"],
        },
    },
    "required": ["url"],
}

_RECOVER_YOUTUBE_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "query": {"type": "string"},
        "channel_hint": {"type": "string"},
    },
    "required": ["query"],
}

_RESOURCE_FINDER_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {"type": "array", "items": {"type": "string"}},
        "category": {
            "type": "string",
            "enum": ["shop", "local", "blog", "news", "web"],
        },
        "original_url": {"type": "string"},
        "visible_urls": {"type": "array", "items": {"type": "string"}},
        "rank_profile": {
            "type": "string",
            "enum": [
                "auto",
                "general",
                "cosmetics",
                "fashion",
                "electronics",
                "local",
                "event_booking",
                "coupang",
                "web",
            ],
        },
        "source_app": {
            "type": "string",
            "enum": [
                "unknown",
                "coupang",
                "naver_map",
                "naver_shopping",
                "oliveyoung",
                "musinsa",
                "instagram",
                "youtube",
                "safari",
                "browser",
            ],
        },
    },
    "required": ["queries", "category"],
}

_SEARCH_PLACE_GEO_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["queries"],
}

# intent_type enum 은 4-Intent(app.shared.intent.Intent)와 동기화 — 안정적이라 하드코딩.
_HYBRID_SEARCH_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {"type": "array", "items": {"type": "string"}},
        "intent_type": {
            "type": "string",
            "enum": ["schedule", "todo", "knowledge", "memo"],
        },
        "occurs_from": {"type": "string"},
        "occurs_to": {"type": "string"},
        "date_from": {"type": "string"},
        "date_to": {"type": "string"},
        "limit": {"type": "integer"},
    },
}

_WEB_SEARCH_PARAMS: dict[str, Any] = {
    "type": "object",
    "properties": {
        "queries": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["queries"],
}


@lru_cache(maxsize=1)
def _shared_client() -> genai.Client:
    settings = get_settings()
    return genai.Client(
        vertexai=True,
        project=settings.google_cloud_project,
        location=settings.gemini_agent_location,
    )


def _function_declarations(tools: list[Tool[Any, Any]]) -> list[types.FunctionDeclaration]:
    decls: list[types.FunctionDeclaration] = []
    for tool in tools:
        if tool.name is ToolName.PLATFORM_CONTEXT:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.PLATFORM_CONTEXT.value,
                    description=(
                        "Fetch low-cost structured context for YouTube, X/Twitter, "
                        "or Instagram URLs. Prefer this over webFetch for those platforms."
                    ),
                    parameters=_PLATFORM_CONTEXT_PARAMS,
                )
            )
        if tool.name is ToolName.WEB_FETCH:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.WEB_FETCH.value,
                    description=(
                        "Fetch a URL's page text to ground the analysis. "
                        "Call only when a URL is present and its content must be read."
                    ),
                    parameters=_WEBFETCH_PARAMS,
                )
            )
        if tool.name is ToolName.RECOVER_YOUTUBE_URL:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.RECOVER_YOUTUBE_URL.value,
                    description=(
                        "Recover the original YouTube watch URL from on-screen clues when the "
                        "capture is a YouTube video/shorts/comments screen with no URL, and the "
                        "thing worth keeping (a recommended item/list, the source video) can only "
                        "be reached by going to the original video. Pass the video title keywords "
                        "you read from the image as 'query', and the video's uploader channel "
                        "(@handle or channel title) as 'channel_hint' — the account that posted the "
                        "video, NOT the viewer's own logged-in profile shown in the UI. It "
                        "disambiguates videos with similar titles to the right channel."
                    ),
                    parameters=_RECOVER_YOUTUBE_PARAMS,
                )
            )
        if tool.name is ToolName.RESOURCE_FINDER:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.RESOURCE_FINDER.value,
                    description=(
                        "Find real reference URLs to attach to a capture so the user can reopen the "
                        "target later. Default to calling this on almost any capture: nearly every "
                        "screenshot points at some real thing (product/place/restaurant/video/brand/"
                        "event/public notice/application/recipe/article) the user might want to "
                        "revisit, and a relevance judge drops weak results, so the safe default is to "
                        "call it. Don't gate on intent_type — todo/schedule/memo/knowledge captures "
                        "need the link too. Call it even when the screenshot is already inside that "
                        "app (Naver Map / Coupang / OliveYoung): the saved memory still needs a link "
                        "to reopen later. Skip only when there is genuinely nothing to look up — a "
                        "private chat, a receipt/confirmation already done, the user's own note, a "
                        "banking/credentials screen, or a personal photo/mood image with nothing "
                        "nameable. YOU extract the keywords from the "
                        "image into 'queries' and choose 'category' (shop=Korean commerce, "
                        "local=place/map, blog=how-to/review/curation incl. 'best-of' lists, "
                        "news=articles, web=overseas/English/general). Also pass rank_profile "
                        "(cosmetics/fashion/local/event_booking/coupang/electronics/web/general) "
                        "and source_app when the screenshot clearly comes from an app. If OCR or "
                        "the screen shows literal URLs, pass them as visible_urls. Returns ranked "
                        "URLs plus reference_entities strings that should be copied into "
                        "entities(kind='reference_url') when useful."
                    ),
                    parameters=_RESOURCE_FINDER_PARAMS,
                )
            )
        if tool.name is ToolName.SEARCH_PLACE_GEO:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.SEARCH_PLACE_GEO.value,
                    description=(
                        "Geocode the specific physical place this capture points at (Naver local "
                        "keyword search → name, category, address, WGS84 coordinates), so the app "
                        "can show it on a map with directions. Call it when the capture is about a "
                        "concrete place the user could visit — a restaurant, cafe, shop, venue, "
                        "exhibition, clinic, office — and you can name it. Pass the place name as "
                        "'queries' (add spacing/branch variants and a region qualifier visible on "
                        "screen, e.g. '로우키 성수'; later variants are fallbacks when the first "
                        "returns nothing). Compare the returned candidates' address/category "
                        "against the capture's evidence, pick the one that IS the captured place, "
                        "and copy its place_entity string verbatim into entities as "
                        '{"kind":"place","value":<that exact string>} — at most one per '
                        "capture, the place the record is about. If no candidate matches, store no "
                        "place entity: a wrong pin is worse than none. Skip it for online-only "
                        "targets, broad areas (a city, a neighborhood), or when no specific place "
                        "is nameable."
                    ),
                    parameters=_SEARCH_PLACE_GEO_PARAMS,
                )
            )
        if tool.name is ToolName.HYBRID_SEARCH:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.HYBRID_SEARCH.value,
                    description=(
                        "Search the user's OWN past records while analyzing this capture — to notice "
                        "if something similar was already saved, connect related records, or see what "
                        "is already planned or due on a day. This does NOT gate saving: even an exact "
                        "duplicate is still saved, so use it to enrich the analysis (summary, "
                        "connections), never to decide whether to store. Matching is hybrid keyword + "
                        "semantic; pass 'queries' (one concept each, several allowed) for what to look "
                        "for. Add filters when useful — intent_type with occurs_from/occurs_to checks "
                        "what is already scheduled or due on a given day. Skip it when the capture "
                        "stands alone with nothing worth cross-referencing."
                    ),
                    parameters=_HYBRID_SEARCH_PARAMS,
                )
            )
        if tool.name is ToolName.WEB_SEARCH:
            decls.append(
                types.FunctionDeclaration(
                    name=ToolName.WEB_SEARCH.value,
                    description=(
                        "Search the public web for external facts that ground a knowledge-type "
                        "capture (what a concept/event/person/term actually is). Use only when "
                        "outside information would materially change the analysis — most captures do "
                        "not need it. NEVER put the record's raw text or any user-identifying phrase "
                        "into a query; rephrase to a generic public query — leaking the capture into "
                        "an external query is exfiltration, not grounding. Pass 'queries' (several "
                        "angles allowed)."
                    ),
                    parameters=_WEB_SEARCH_PARAMS,
                )
            )
    decls.append(
        types.FunctionDeclaration(
            name=_FINALIZE,
            description="Emit the final structured analysis. Call exactly once when ready.",
            parameters=_FINALIZE_PARAMS,
        )
    )
    return decls


def _to_contents(user_parts: list[dict[str, Any]]) -> list[types.Content]:
    """orchestrator 의 정규화 대화(list[dict])를 genai Content 로 변환."""
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
            # 멀티모달 입력: gs:// 이미지를 같은 user turn 에 첨부 (Gemini 가 직접 read).
            for uri, mime in part.get("images", []):
                content_parts.append(types.Part.from_uri(file_uri=uri, mime_type=mime))
            contents.append(types.Content(role=part.get("role", "user"), parts=content_parts))
    return contents


async def _call(
    *,
    system_prompt: str,
    contents: list[types.Content],
    decls: list[types.FunctionDeclaration],
    model: str,
) -> Any:
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=4096,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        tools=[types.Tool(function_declarations=decls)],
        tool_config=types.ToolConfig(function_calling_config=types.FunctionCallingConfig(mode="ANY")),
    )
    return await _shared_client().aio.models.generate_content(
        model=model, contents=cast(types.ContentListUnion, contents), config=cfg
    )


def _extract_function_call(resp: Any) -> tuple[str, dict[str, Any], bytes | None] | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None):
                # thought_signature 는 Part 에 실린다 (FunctionCall 이 아니라). 멀티턴 echo 필수.
                return fc.name, dict(fc.args or {}), getattr(part, "thought_signature", None)
    return None


class GeminiAgentClient(LLMClient):
    """Arch2 agent loop 용 Gemini function-calling 클라이언트."""

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
        contents = _to_contents(user_parts)
        resp = await asyncio.wait_for(
            _call(
                system_prompt=system_prompt,
                contents=contents,
                decls=decls,
                model=self._model,
            ),
            timeout=self._timeout,
        )
        tokens_in, tokens_out = extract_token_usage(resp)
        fc = _extract_function_call(resp)
        if fc is None:
            logger.warning("agent.llm.no_function_call", model=self._model)
            text = getattr(resp, "text", None)
            yield LLMResponseChunk(
                text_delta=text or "",
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                model=self._model,
            )
            return
        name, args, signature = fc
        logger.info(
            "agent.llm.function_call",
            model=self._model,
            function_name=name,
            arg_keys=sorted(args.keys()),
            has_thought_signature=signature is not None,
        )
        if name == _FINALIZE:
            args["model_version"] = self._model
            yield LLMResponseChunk(
                final_payload=args, tokens_in=tokens_in, tokens_out=tokens_out, model=self._model
            )
        else:
            yield LLMResponseChunk(
                tool_to_call=ToolName(name),
                tool_arguments=args,
                thought_signature=signature,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                model=self._model,
            )
