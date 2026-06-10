"""채팅 agent run — detached task 의 본체.

생성/전달 분리(journal 2026-06-10): 이 루프는 클라이언트 연결과 무관하게 **완주**하며,
각 단계를 즉시 영속(``ChatTurnStore`` — 연산마다 자체 세션 commit)하고 이벤트는
``RunRegistry`` 큐로 best-effort 중계만 한다. 끊김은 전달 문제일 뿐 데이터는 불변.

루프는 read-only — 쓰기 가능한 툴은 레지스트리에 없다(테스트가 고정). 한도 초과는
에러가 아니라 "지금까지 찾은 걸로 답변" 폴백이다.
"""

import asyncio
import re
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

_CITATION_PATTERN = re.compile(r"【item:([0-9a-fA-F-]{36})】")

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
            await self._fail(owner_id, run_id, code="chat.run_timeout", message="답변 생성이 너무 오래 걸렸어요")
        except Exception as exc:  # noqa: BLE001 — detached task 의 마지막 방어선
            logger.error("chat.run.failed", run_id=str(run_id), error=str(exc), exc_info=exc)
            await self._fail(owner_id, run_id, code="chat.run_failed", message="답변을 생성하지 못했어요")
        finally:
            self.registry.close(run_id)

    # MARK: 본 루프

    async def _run(self, *, owner_id: UUID, conversation_id: UUID, run_id: UUID) -> None:
        history = await self.store.load_history(owner_id=owner_id, conversation_id=conversation_id)
        contents = _contents_from_history(history)
        system_prompt = self._system_prompt()

        assistant_text = ""
        proposals: list[dict[str, Any]] = []
        calls = 0
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
            ):
                if chunk.text_delta:
                    round_text += chunk.text_delta
                    assistant_text += chunk.text_delta
                    self._publish(run_id, run_events.MESSAGE_DELTA, {"text": chunk.text_delta})
                if chunk.tool_call is not None:
                    name, args = chunk.tool_call
                    round_calls.append((name, args, chunk.thought_signature))

            if round_text:
                contents.append({"role": "model", "text": round_text})
            if not round_calls:
                break
            if round_text:
                # 툴콜 전 선행 텍스트("찾아볼게요")와 다음 라운드 답변이 무구분 연결되지 않게
                # 경계 개행 — 스트림과 영속본 양쪽에 동일 반영해 스냅샷 정합 유지 (리뷰 P2).
                assistant_text += "\n"
                self._publish(run_id, run_events.MESSAGE_DELTA, {"text": "\n"})

            for name, args, signature in round_calls:
                if calls >= self.max_tool_calls:
                    # 콜 예산 소진 — 잔여 콜은 미실행·미기록(contents 정합 유지), 다음 라운드 폴백이 답변을 끌어낸다.
                    break
                calls += 1
                result = await self._execute_tool(
                    owner_id=owner_id, conversation_id=conversation_id, run_id=run_id,
                    name=name, args=args,
                )
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
                contents.append(
                    {"function_call": {"name": name, "args": args}, "thought_signature": signature}
                )
                contents.append({"function_response": {"name": name, "response": result.payload}})

        if not assistant_text.strip():
            raise RuntimeError("LLM produced no answer text")

        message_id = await self._persist_answer(
            owner_id=owner_id,
            conversation_id=conversation_id,
            run_id=run_id,
            text=assistant_text,
            proposals=proposals,
        )
        await self.store.set_run_status(owner_id=owner_id, run_id=run_id, status=RunStatus.COMPLETED)
        self._publish(run_id, run_events.DONE, {"message_id": str(message_id)})

    async def _execute_tool(
        self, *, owner_id: UUID, conversation_id: UUID, run_id: UUID,
        name: str, args: dict[str, Any],
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
            result = ChatToolResult(
                payload={"error": "tool execution failed"}, summary="잠깐 막혔어요"
            )
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
        self._publish(
            run_id, run_events.TOOL_FINISHED, {"name": tool.name, "summary": result.summary}
        )
        return result

    async def _persist_answer(
        self,
        *,
        owner_id: UUID,
        conversation_id: UUID,
        run_id: UUID,
        text: str,
        proposals: list[dict[str, Any]] | None = None,
    ) -> UUID:
        """citation 마커 파싱·owner 검증 → assistant 행 + citations 영속 + citation 이벤트."""
        marker_ids: list[UUID] = []
        for raw in _CITATION_PATTERN.findall(text):
            try:
                marker_id = UUID(raw)
            except ValueError:
                continue
            if marker_id not in marker_ids:
                marker_ids.append(marker_id)
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

    def _system_prompt(self) -> str:
        now = datetime.now(ZoneInfo(_TIMEZONE))
        # str.format 은 본문의 다른 중괄호와 충돌할 수 있어 명시 replace.
        return self.prompt.body.replace("{now}", now.strftime("%Y-%m-%d %A %H:%M")).replace(
            "{timezone}", _TIMEZONE
        )

    def _publish(self, run_id: UUID, kind: str, payload: dict[str, Any]) -> None:
        self.registry.publish(run_id, ChatEvent(kind=kind, payload={"run_id": str(run_id), **payload}))

    async def _fail(self, owner_id: UUID, run_id: UUID, *, code: str, message: str) -> None:
        try:
            await self.store.set_run_status(owner_id=owner_id, run_id=run_id, status=RunStatus.FAILED)
        finally:
            self._publish(run_id, run_events.ERROR, {"code": code, "message": message})


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
            contents.append({"function_call": {"name": name, "args": payload.get("args", {})}})
            contents.append({"function_response": {"name": name, "response": response}})
    return contents
