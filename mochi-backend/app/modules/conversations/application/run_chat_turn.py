"""채팅 agent run — detached task 의 본체.

생성/전달 분리(journal 2026-06-10): 이 루프는 클라이언트 연결과 무관하게 **완주**하며,
각 단계를 즉시 영속(``ChatTurnStore`` — 연산마다 자체 세션 commit)하고 이벤트는
``RunRegistry`` 큐로 best-effort 중계만 한다. 끊김은 전달 문제일 뿐 데이터는 불변.

루프는 read-only — 쓰기 가능한 툴은 레지스트리에 없다(테스트가 고정). 한도 초과는
에러가 아니라 "지금까지 찾은 걸로 답변" 폴백이다.
"""

import asyncio
import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import structlog

from app.modules.agent.prompts.system_prompts import PromptVersion
from app.modules.conversations.domain import run_events
from app.modules.conversations.domain.entities import (
    Message,
    MessageCitation,
    MessageRole,
    RunStatus,
)
from app.modules.conversations.domain.ports import (
    ChatLLMClient,
    ChatTool,
    ChatToolResult,
    ChatTurnStore,
)
from app.modules.conversations.domain.run_events import ChatEvent
from app.modules.conversations.infrastructure.run_registry import RunRegistry

logger = structlog.get_logger(__name__)

MAX_ROUNDS = 5
MAX_TOOL_CALLS = 8
_TIMEZONE = "Asia/Seoul"
#: 프로필 로드 상한 — 프로필은 부가라, DB 가 막혀도 전체 run timeout 을 태우지 않고 빨리 포기한다.
_PROFILE_LOAD_TIMEOUT = 3.0

# 전각 「【item:id】」 이 canonical 이지만, 작은 모델이 반각 괄호를 쓰거나 UUID 를 앞 8자로
# 줄이는 경우도 수용한다. 짧은 토큰은 현재 턴의 owner-scoped 도구 결과 안에서 유일할 때만
# 전체 UUID 로 복구한다(``_resolve_marker_ids``) — DB 전체 prefix 추측은 하지 않는다.
_CITATION_PATTERN = re.compile(r"[【\[]item:([0-9a-fA-F-]{8,36})[】\]]")

#: 한도 도달 시 마지막 라운드에 주입 — 에러 대신 폴백 답변을 끌어낸다.
_FALLBACK_INSTRUCTION = (
    "(system) Tool budget is exhausted. Answer now in Korean with what you have gathered; "
    "if it is not enough, say honestly what you could not find."
)


@dataclass(slots=True)
class RunChatTurn:
    llm: ChatLLMClient
    tools: list[ChatTool]
    store: ChatTurnStore
    registry: RunRegistry
    prompt: PromptVersion
    timeout_seconds: float = 60.0
    max_rounds: int = MAX_ROUNDS
    max_tool_calls: int = MAX_TOOL_CALLS
    #: owner_id → 채팅용 페르소나 프로필(없으면 None). 세션-독립 콜백을 composition root 가
    #: 주입한다(detached run 이라 자체 세션을 매 호출 연다). None 이면 프로필 주입 없이 동작.
    profile_loader: Callable[[UUID], Awaitable[str | None]] | None = None
    _tool_by_name: dict[str, ChatTool] = field(init=False, default_factory=dict)

    def __post_init__(self) -> None:
        self._tool_by_name = {tool.name: tool for tool in self.tools}

    async def execute(self, *, owner_id: UUID, conversation_id: UUID, run_id: UUID) -> None:
        """run 전체 — 타임아웃·예외를 여기서 흡수해 status/error 이벤트로 변환한다."""
        try:
            await asyncio.wait_for(
                self._run(owner_id=owner_id, conversation_id=conversation_id, run_id=run_id),
                timeout=self.timeout_seconds,
            )
        except TimeoutError:
            await self._fail(
                owner_id, run_id, code="chat.run_timeout", message="답변 생성이 너무 오래 걸렸어요"
            )
        except Exception as exc:  # noqa: BLE001 — detached task 의 마지막 방어선
            logger.error("chat.run.failed", run_id=str(run_id), error=str(exc), exc_info=exc)
            await self._fail(owner_id, run_id, code="chat.run_failed", message="답변을 생성하지 못했어요")
        finally:
            self.registry.close(run_id)

    # MARK: 본 루프

    async def _run(self, *, owner_id: UUID, conversation_id: UUID, run_id: UUID) -> None:
        history = await self.store.load_history(owner_id=owner_id, conversation_id=conversation_id)
        contents = _contents_from_history(history)
        profile = await self._load_profile(owner_id, run_id)
        system_prompt = self._system_prompt(profile=profile)

        assistant_text = ""
        proposals: list[dict[str, Any]] = []
        citation_candidates: list[UUID] = []
        calls = 0
        llm_tokens_in = 0
        llm_tokens_out = 0
        llm_model: str | None = None
        for round_index in range(self.max_rounds):
            final_round = round_index == self.max_rounds - 1 or calls >= self.max_tool_calls
            if final_round and round_index > 0:
                contents.append({"role": "user", "text": _FALLBACK_INSTRUCTION})

            round_text = ""
            round_calls: list[tuple[str, dict[str, Any], bytes | None]] = []
            async for chunk in self.llm.stream(
                system_prompt=system_prompt,
                contents=contents,
                tools=[] if final_round else self.tools,
                # 턴의 첫 라운드는 함수 호출 강제(ANY) — '답하기 전 검색'을 프롬프트가 아니라
                # 기계로 보장한다. 인사 같은 발화에도 검색 1회가 나가는 비용은 회수 누락보다 싸다.
                force_tool=round_index == 0 and not final_round and bool(self.tools),
            ):
                if chunk.text_delta:
                    round_text += chunk.text_delta
                    assistant_text += chunk.text_delta
                    self._publish(run_id, run_events.MESSAGE_DELTA, {"text": chunk.text_delta})
                if chunk.tool_call is not None:
                    name, args = chunk.tool_call
                    round_calls.append((name, args, chunk.thought_signature))
                llm_tokens_in += chunk.tokens_in
                llm_tokens_out += chunk.tokens_out
                if chunk.model:
                    llm_model = chunk.model

            if round_text:
                contents.append({"role": "model", "text": round_text})
            if not round_calls:
                break
            if round_text:
                # 툴콜 전 선행 텍스트("찾아볼게요")와 다음 라운드 답변이 무구분 연결되지 않게
                # 경계 개행 — 스트림과 영속본 양쪽에 동일 반영해 스냅샷 정합 유지 (리뷰 P2).
                assistant_text += "\n"
                self._publish(run_id, run_events.MESSAGE_DELTA, {"text": "\n"})

            round_images: list[tuple[str, str]] = []
            executed_calls: list[dict[str, Any]] = []
            executed_responses: list[dict[str, Any]] = []
            for name, args, signature in round_calls:
                if calls >= self.max_tool_calls:
                    # 콜 예산 소진 — 잔여 콜은 미실행·미기록(contents 정합 유지), 다음 라운드 폴백이 답변을 끌어낸다.
                    break
                calls += 1
                result = await self._execute_tool(
                    owner_id=owner_id,
                    conversation_id=conversation_id,
                    run_id=run_id,
                    name=name,
                    args=args,
                )
                for candidate in _citation_candidates(name, result.payload):
                    if candidate not in citation_candidates:
                        citation_candidates.append(candidate)
                if result.proposal is not None:
                    # propose_* 툴의 확인 카드 — 쓰기 없음. 즉시 스트림으로 흘리고
                    # assistant 행 영속 시 proposals 에 함께 싣는다(스냅샷 재조회 정합).
                    proposals.append(result.proposal)
                    self._publish(
                        run_id,
                        run_events.PROPOSAL,
                        {
                            "id": result.proposal["id"],
                            "type": result.proposal["type"],
                            "payload": result.proposal["payload"],
                        },
                    )
                executed_calls.append({"name": name, "args": args, "thought_signature": signature})
                executed_responses.append({"name": name, "response": result.payload})
                round_images.extend(result.images)
            if executed_calls:
                # 같은 라운드의 병렬 fc/fr 는 각각 **하나의** model/user turn 으로 묶는다.
                # thinking 활성 시 thought_signature 는 라운드 첫 fc part 에만 오므로,
                # 콜마다 별도 Content 로 쪼개면 시그니처 없는 model FC step 이 생겨
                # 다음 라운드 요청이 Gemini 시그니처 검증(400)에 걸린다 (리뷰 P1).
                contents.append({"function_calls": executed_calls})
                contents.append({"function_responses": executed_responses})
            if round_images:
                # 이미지는 function_response(JSON)에 실을 수 없어 별도 user part 로 첨부
                # (Part 변환은 분석 경로와 동형 — Vertex 직접 read). 라운드의 모든
                # function_call/response 쌍이 닫힌 **뒤** 한 번만 — 병렬 툴콜 시퀀스
                # 사이에 user turn 이 끼면 Gemini contents 검증이 깨진다 (리뷰 P1).
                # 현재 턴 in-memory 전용: tool 행 영속엔 compact 만 남아 과거 턴
                # 히스토리에 재주입되지 않는다(토큰 비용).
                contents.append(
                    {
                        "role": "user",
                        "text": (
                            f"(attached: {len(round_images)} image(s) from the view_item_image results above)"
                        ),
                        "images": round_images,
                    }
                )

        if not assistant_text.strip():
            raise RuntimeError("LLM produced no answer text")

        message_id = await self._persist_answer(
            owner_id=owner_id,
            conversation_id=conversation_id,
            run_id=run_id,
            text=assistant_text,
            proposals=proposals,
            citation_candidates=citation_candidates,
        )
        try:
            await self.store.record_usage(
                owner_id=owner_id,
                conversation_id=conversation_id,
                model=llm_model or "unknown",
                tokens_in=llm_tokens_in,
                tokens_out=llm_tokens_out,
            )
        except Exception as exc:  # noqa: BLE001 — 계측 실패가 답변 완료를 막지 않는다
            logger.warning("chat.usage_record_failed", run_id=str(run_id), error=str(exc))
        await self.store.set_run_status(owner_id=owner_id, run_id=run_id, status=RunStatus.COMPLETED)
        self._publish(run_id, run_events.DONE, {"message_id": str(message_id)})

    async def _execute_tool(
        self,
        *,
        owner_id: UUID,
        conversation_id: UUID,
        run_id: UUID,
        name: str,
        args: dict[str, Any],
    ) -> ChatToolResult:
        tool = self._tool_by_name.get(name)
        if tool is None:
            # 모델 환각으로 미선언 툴 호출 — 에러를 function_response 로 돌려 스스로 복구하게.
            logger.warning("chat.run.unknown_tool", run_id=str(run_id), tool=name)
            return ChatToolResult(payload={"error": f"unknown tool: {name}"}, summary="")

        self._publish(run_id, run_events.TOOL_STARTED, {"name": tool.name, "label": tool.label})
        try:
            result = await tool.run(owner_id=owner_id, args=args)
        except Exception as exc:  # noqa: BLE001 — 툴 실패는 run 실패가 아니라 모델이 다룰 정보
            logger.warning("chat.run.tool_failed", run_id=str(run_id), tool=name, error=str(exc))
            result = ChatToolResult(payload={"error": "tool execution failed"}, summary="잠깐 막혔어요")
        await self.store.append(
            owner_id=owner_id,
            message=Message(
                id=uuid4(),
                conversation_id=conversation_id,
                role=MessageRole.TOOL,
                tool_name=tool.name,
                tool_payload={"args": args, "summary": result.summary, "compact": result.compact},
                run_id=run_id,
            ),
        )
        self._publish(run_id, run_events.TOOL_FINISHED, {"name": tool.name, "summary": result.summary})
        return result

    async def _persist_answer(
        self,
        *,
        owner_id: UUID,
        conversation_id: UUID,
        run_id: UUID,
        text: str,
        proposals: list[dict[str, Any]] | None = None,
        citation_candidates: list[UUID] | None = None,
    ) -> UUID:
        """citation 마커 파싱·owner 검증 → assistant 행 + citations 영속 + citation 이벤트."""
        marker_ids = _resolve_marker_ids(text, citation_candidates or [])
        resolved = await self.store.resolve_citations(owner_id=owner_id, mochi_item_ids=marker_ids)

        citations = tuple(
            MessageCitation(
                mochi_item_id=item.mochi_item_id,
                citation_index=index,
                title=item.title,
                snippet=item.snippet,
            )
            for index, item in enumerate(resolved, start=1)
        )
        message = Message(
            id=uuid4(),
            conversation_id=conversation_id,
            role=MessageRole.ASSISTANT,
            content=text,  # 마커 원문 보존 — 스냅샷 재조회 시 iOS 가 동일 치환
            run_id=run_id,
            proposals=tuple(proposals or ()),
            citations=citations,
        )
        await self.store.append(owner_id=owner_id, message=message)
        for citation in citations:
            self._publish(
                run_id,
                run_events.CITATION,
                {
                    "index": citation.citation_index,
                    "item_id": str(citation.mochi_item_id),
                    "title": citation.title,
                    "snippet": citation.snippet,
                },
            )
        return message.id

    # MARK: helpers

    async def _load_profile(self, owner_id: UUID, run_id: UUID) -> str | None:
        """채팅용 페르소나 프로필 로드 — best-effort. 로딩 실패가 채팅을 막지 않는다."""
        if self.profile_loader is None:
            return None
        try:
            return await asyncio.wait_for(self.profile_loader(owner_id), timeout=_PROFILE_LOAD_TIMEOUT)
        except Exception as exc:  # noqa: BLE001 — 프로필은 부가, 실패·지연해도 답변은 진행
            logger.warning("chat.profile_load_failed", run_id=str(run_id), error=str(exc))
            return None

    def _system_prompt(self, *, profile: str | None = None) -> str:
        now = datetime.now(ZoneInfo(_TIMEZONE))
        # str.format 은 본문의 다른 중괄호와 충돌할 수 있어 명시 replace.
        return (
            self.prompt.body.replace("{profile}", _profile_block(profile))
            # offset(+0900)을 실어 준다 — 이게 없으면 모델이 "1분 뒤" 같은 상대시각을 벽시계로
            # 옳게 계산해 놓고 offset 만 Z/+00:00 로 잘못 붙여 낼 여지가 생겨, 알림이 +9h 밀려
            # "다음날" 발화한다. 숫자 offset 을 보여 KST 로 내도록 유도한다.
            .replace("{now}", now.strftime("%Y-%m-%d %A %H:%M %z"))
            .replace("{timezone}", _TIMEZONE)
        )

    def _publish(self, run_id: UUID, kind: str, payload: dict[str, Any]) -> None:
        self.registry.publish(run_id, ChatEvent(kind=kind, payload={"run_id": str(run_id), **payload}))

    async def _fail(self, owner_id: UUID, run_id: UUID, *, code: str, message: str) -> None:
        try:
            await self.store.set_run_status(owner_id=owner_id, run_id=run_id, status=RunStatus.FAILED)
        finally:
            self._publish(run_id, run_events.ERROR, {"code": code, "message": message})


_CITABLE_TOOL_NAMES = frozenset(
    {"search_items", "get_item_detail", "view_item_image", "list_notifications"}
)


def _citation_candidates(tool_name: str, payload: dict[str, Any]) -> list[UUID]:
    """현재 턴의 기록 조회 도구가 실제 반환한 item UUID 만 citation 후보로 모은다."""
    if tool_name not in _CITABLE_TOOL_NAMES:
        return []
    rows: list[dict[str, Any]] = [payload]
    for key in ("items", "notifications"):
        value = payload.get(key)
        if isinstance(value, list):
            rows.extend(row for row in value if isinstance(row, dict))

    candidates: list[UUID] = []
    for row in rows:
        for key in ("id", "mochi_item_id"):
            raw = row.get(key)
            try:
                candidate = UUID(str(raw))
            except (TypeError, ValueError, AttributeError):
                continue
            if candidate not in candidates:
                candidates.append(candidate)
    return candidates


def _resolve_marker_ids(text: str, candidates: list[UUID]) -> list[UUID]:
    """본문 marker 를 입력 순서대로 UUID 로 복구한다.

    전체 UUID 는 기존처럼 owner 검증 단계로 넘긴다. 축약 토큰은 이번 답변의 도구 결과 중
    유일한 prefix 일 때만 허용해 다른 기록을 잘못 인용하는 것보다 citation 누락을 택한다.
    """
    resolved: list[UUID] = []
    for raw in _CITATION_PATTERN.findall(text):
        try:
            marker_id = UUID(raw)
        except ValueError:
            prefix = raw.lower()
            matches = [candidate for candidate in candidates if str(candidate).startswith(prefix)]
            if len(matches) != 1:
                continue
            marker_id = matches[0]
        if marker_id not in resolved:
            resolved.append(marker_id)
    return resolved


def _profile_block(profile: str | None) -> str:
    """채팅 system prompt 의 ``{profile}`` 슬롯 본문. 프로필이 없으면 빈 문자열 — 신규 유저는
    V10 거동과 동일하게 슬롯이 사라진다. 문구가 역할을 못박는다: 배경·톤 전용, 사실 출처 아님
    (검색 회귀 방지 — doc-guardian 이 짚은 V10 '되묻지 말고 검색' 규칙과의 충돌 가드)."""
    if not profile or not profile.strip():
        return ""
    return (
        "\n# Who you're speaking with\n"
        "- A short portrait of this user, distilled from everything they've saved — their "
        "interests, tastes, and the texture of their life right now. Let it set your tone and "
        "help you read what they're really after, so you speak like someone who already knows "
        "them.\n"
        "- But this is who they are, not a record of what they saved: never cite it with an "
        "【item】 marker, never state it back as a fact they stored, and still recover every "
        "concrete detail (plans, to-dos, specific items, dates) by searching. Background for "
        "how you speak — never a source for what you claim.\n"
        f"- {profile.strip()}\n"
    )


def _contents_from_history(history: list[Message]) -> list[dict[str, Any]]:
    """영속 메시지 → LLM 대화. 과거 턴 tool 행은 ``compact`` 축약본으로 재구성한다 —
    tool result 가 토큰의 대부분이라, 풀 버전은 현재 턴 in-memory 에만 존재한다."""
    contents: list[dict[str, Any]] = []
    for message in history:
        if message.role is MessageRole.USER:
            contents.append({"role": "user", "text": message.content or ""})
        elif message.role is MessageRole.ASSISTANT:
            contents.append({"role": "model", "text": message.content or ""})
        else:
            payload = message.tool_payload or {}
            name = message.tool_name or "tool"
            response: dict[str, Any] = dict(payload.get("compact") or {})
            if summary := payload.get("summary"):
                response.setdefault("summary", summary)
            contents.append({"function_calls": [{"name": name, "args": payload.get("args", {})}]})
            contents.append({"function_responses": [{"name": name, "response": response}]})
    return contents
