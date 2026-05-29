import hashlib
import json
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import datetime
from time import perf_counter
from typing import Any
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.modules.agent.domain.analysis import AnalysisResult, ExtractedEntity
from app.modules.agent.domain.gateway import AnalysisInput, MochiItemGateway
from app.modules.agent.domain.ports import LLMClient, ToolRegistry
from app.modules.agent.domain.profile import UserProfileStore
from app.modules.agent.domain.run import AgentRun, ToolCall
from app.modules.agent.domain.states import HAPPY_PATH, AgentNode
from app.modules.agent.domain.tools import ToolExecutionError, ToolName, ToolUsage
from app.modules.agent.infrastructure.tools.multimodal_analyze import MultimodalAnalyzeOutput
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT

log = get_logger("agent")


@dataclass(slots=True)
class StreamEvent:
    kind: str           # "node" | "tool_started" | "tool_finished" | "partial" | "final" | "failed"
    payload: dict[str, Any]


class AgentOrchestrator:
    """MochiItem 한 건을 state graph(ingested → … → synced)를 따라 진행한다.

    책임:
    - 노드 전이의 결정성 + 모든 전환을 ``StreamEvent`` 로 노출 (iOS SSE 점진 UI)
    - ``ANALYZED``: 실제 agentic function-calling 루프 — LLM 이 분석가이고
      ``webFetch`` 로 URL 을 그라운딩한 뒤 ``finalizeAnalysis`` 로 구조화 분석을 저술.
      개인화 프로필이 있으면 system prompt 에 주입한다. ``max_steps`` 상한.
    - ``PERSISTED``: 분석 결과를 ``MochiItemGateway`` 로 write-back.
    - DB 세션 주입 시 `agent_runs` / `tool_calls` 행 persist + 모든 tool usage 누적.

    실패 시 ``failed`` 이벤트를 흘리고 예외를 re-raise 한다 — 워커가 outbox
    재시도/DLQ 분기를 판단할 수 있도록.
    """

    def __init__(
        self,
        llm: LLMClient,
        tools: ToolRegistry,
        *,
        max_steps: int,
        persistence: "AgentRunPersistence | None" = None,
        gateway: MochiItemGateway | None = None,
        profile_store: UserProfileStore | None = None,
    ):
        self._llm = llm
        self._tools = tools
        self._max_steps = max_steps
        self._persistence = persistence
        self._gateway = gateway
        self._profile_store = profile_store

    async def run(self, mochi_item_id: UUID, owner_id: UUID) -> AsyncIterator[StreamEvent]:
        agent_run = AgentRun(mochi_item_id=mochi_item_id)

        if self._persistence is not None:
            await self._persistence.start(agent_run)

        try:
            analysis: AnalysisResult | None = None
            for node in HAPPY_PATH:
                agent_run.advance(node)
                yield StreamEvent("node", {"node": node.value, "run_id": str(agent_run.id)})
                if self._persistence is not None:
                    await self._persistence.update_node(agent_run.id, node)

                if node is AgentNode.ANALYZED and self._gateway is not None:
                    # gateway 가 없으면(예: /stream progress shell) 분석/ write-back 을 건너뛴다 —
                    # 실제 분석은 outbox 워커(gateway 주입)가 단일 소유한다 (이중 실행 방지).
                    async for event in self._analyze(agent_run, owner_id, mochi_item_id):
                        if isinstance(event, AnalysisResult):
                            analysis = event
                        else:
                            yield event
                elif (
                    node is AgentNode.PERSISTED
                    and analysis is not None
                    and self._gateway is not None
                ):
                    await self._gateway.apply_analysis(
                        owner_id=owner_id, mochi_item_id=mochi_item_id, result=analysis
                    )

            agent_run.succeed()
            if self._persistence is not None:
                await self._persistence.finish(agent_run)
            yield StreamEvent("final", {"run_id": str(agent_run.id), "tokens": agent_run.total_tokens})
        except Exception as exc:
            agent_run.fail(str(exc))
            if self._persistence is not None:
                await self._persistence.fail(agent_run, reason=str(exc))
            yield StreamEvent("failed", {"run_id": str(agent_run.id), "message": str(exc)})
            raise

    async def _analyze(
        self, agent_run: AgentRun, owner_id: UUID, mochi_item_id: UUID
    ) -> "AsyncIterator[StreamEvent | AnalysisResult]":
        """agentic 루프. 진행 StreamEvent 들을 yield 하고, 마지막에 ``AnalysisResult`` 를 yield."""
        if self._gateway is None:
            raise RuntimeError("gateway is required for analysis")
        source = await self._gateway.load_source(owner_id=owner_id, mochi_item_id=mochi_item_id)
        if source is None:
            raise RuntimeError(f"mochi item {mochi_item_id} not found for analysis")

        profile_summary: str | None = None
        if self._profile_store is not None:
            profile = await self._profile_store.get(owner_id=owner_id)
            profile_summary = profile.summary if profile else None
        system_prompt = ACTIVE_PROMPT.body + _profile_preamble(profile_summary)

        first_user: dict[str, Any] = {"role": "user", "text": _initial_user_text(source)}
        if source.images:
            first_user["images"] = list(source.images)
        parts: list[dict[str, Any]] = [first_user]
        final_payload: dict[str, Any] | None = None

        for _ in range(self._max_steps):
            chunk = None
            async for c in self._llm.stream(
                system_prompt=system_prompt,
                user_parts=parts,
                tools=self._tools.all(),
                thought_signature=None,
            ):
                chunk = c
            if chunk is None:
                break
            if chunk.final_payload is not None:
                final_payload = chunk.final_payload
                break
            if chunk.tool_to_call is not None:
                async for ev in self._run_tool(
                    agent_run,
                    chunk.tool_to_call,
                    chunk.tool_arguments or {},
                    chunk.thought_signature,
                    parts,
                ):
                    yield ev
                continue
            break

        if final_payload is None:
            raise RuntimeError("agent loop exhausted without producing a final analysis")

        analysis = _to_analysis_result(final_payload)
        yield StreamEvent(
            "partial",
            {"summary": analysis.summary, "intent": analysis.intent.value, "run_id": str(agent_run.id)},
        )
        yield analysis

    async def _run_tool(
        self,
        agent_run: AgentRun,
        tool_name: ToolName,
        args: dict[str, Any],
        thought_signature: bytes | None,
        parts: list[dict[str, Any]],
    ) -> AsyncIterator[StreamEvent]:
        yield StreamEvent("tool_started", {"name": tool_name.value, "run_id": str(agent_run.id)})
        tool = self._tools.get(tool_name)
        started = perf_counter()
        # 직전 functionCall part 에 thought_signature 를 실어 다음 turn 에 echo (Gemini 3 필수).
        parts.append(
            {
                "role": "model",
                "function_call": {"name": tool_name.value, "args": args},
                "thought_signature": thought_signature,
            }
        )
        try:
            out, usage = await tool.run(tool.input_model.model_validate(args))
            response = out.model_dump()
            if isinstance(response.get("text"), str):
                response["text"] = response["text"][:4000]   # 토큰 bound
            succeeded = True
        except ToolExecutionError as exc:
            usage = ToolUsage()
            response = {"error": str(exc)}        # 에러를 모델에 되먹여 recover/finalize 유도
            succeeded = False
        parts.append(
            {"role": "user", "function_response": {"name": tool_name.value, "response": response}}
        )

        call = ToolCall(
            name=tool_name,
            input_digest=_digest(args),
            output_digest=None,
            tokens_in=usage.tokens_in,
            tokens_out=usage.tokens_out,
            latency_ms=int((perf_counter() - started) * 1000),
            succeeded=succeeded,
        )
        agent_run.record(call)
        if self._persistence is not None:
            await self._persistence.record_tool_call(
                run_id=agent_run.id,
                name=call.name.value,
                input_digest=call.input_digest,
                output_digest=call.output_digest,
                tokens_in=call.tokens_in,
                tokens_out=call.tokens_out,
                latency_ms=call.latency_ms,
                succeeded=call.succeeded,
            )
        yield StreamEvent(
            "tool_finished",
            {"name": tool_name.value, "ok": succeeded, "run_id": str(agent_run.id)},
        )


class AgentRunPersistence:
    """`agent_runs` / `tool_calls` 테이블에 한 트랜잭션으로 적재한다.

    - `start` 는 행을 INSERT 하고 commit 한다 (이후 노드 업데이트가 같은 행을 가리킨다)
    - `finish` / `fail` 는 같은 행의 `current_node`, `ended_at`, `failure_reason` 갱신
    - `record_tool_call` 은 별도 행을 INSERT 한다
    """

    def __init__(self, session: AsyncSession):
        self._session = session

    async def start(self, run: AgentRun) -> None:
        await self._session.execute(
            text(
                """
                INSERT INTO agent_runs (id, mochi_item_id, current_node, total_tokens, total_latency_ms, started_at)
                VALUES (:id, :mochi_item_id, :node, 0, 0, :started_at)
                """
            ),
            {
                "id": run.id,
                "mochi_item_id": run.mochi_item_id,
                "node": run.current_node.value,
                "started_at": run.started_at,
            },
        )
        await self._session.commit()

    async def update_node(self, run_id: UUID, node: AgentNode) -> None:
        await self._session.execute(
            text("UPDATE agent_runs SET current_node=:node WHERE id=:id"),
            {"id": run_id, "node": node.value},
        )
        await self._session.commit()

    async def finish(self, run: AgentRun) -> None:
        await self._session.execute(
            text(
                """
                UPDATE agent_runs
                SET current_node=:node, ended_at=:ended_at,
                    total_tokens=:tokens, total_latency_ms=:latency
                WHERE id=:id
                """
            ),
            {
                "id": run.id,
                "node": run.current_node.value,
                "ended_at": run.ended_at or datetime.utcnow(),
                "tokens": run.total_tokens,
                "latency": run.total_latency_ms,
            },
        )
        await self._session.commit()

    async def fail(self, run: AgentRun, *, reason: str) -> None:
        await self._session.execute(
            text(
                """
                UPDATE agent_runs
                SET current_node='failed', ended_at=:ended_at, failure_reason=:reason
                WHERE id=:id
                """
            ),
            {"id": run.id, "ended_at": datetime.utcnow(), "reason": reason[:1024]},
        )
        await self._session.commit()

    async def record_tool_call(
        self,
        *,
        run_id: UUID,
        name: str,
        input_digest: str,
        output_digest: str | None,
        tokens_in: int,
        tokens_out: int,
        latency_ms: int,
        succeeded: bool,
    ) -> None:
        await self._session.execute(
            text(
                """
                INSERT INTO tool_calls
                    (agent_run_id, name, input_digest, output_digest,
                     tokens_in, tokens_out, latency_ms, succeeded)
                VALUES
                    (:run_id, :name, :in_digest, :out_digest,
                     :tin, :tout, :lat, :ok)
                """
            ),
            {
                "run_id": run_id,
                "name": name,
                "in_digest": input_digest,
                "out_digest": output_digest,
                "tin": tokens_in,
                "tout": tokens_out,
                "lat": latency_ms,
                "ok": succeeded,
            },
        )
        await self._session.commit()


def _profile_preamble(summary: str | None) -> str:
    if not summary:
        return ""
    return f"\n\n# 사용자 컨텍스트\n{summary}\n"


def _initial_user_text(source: AnalysisInput) -> str:
    blocks: list[str] = []
    if source.text:
        blocks.append(f"내용:\n{source.text}")
    if source.url:
        blocks.append(f"URL: {source.url}")
    if source.user_memo:
        blocks.append(f"사용자 메모: {source.user_memo}")
    text = "\n\n".join(blocks)
    if text:
        return text
    return "첨부된 스크린샷을 분석해 주세요." if source.images else "(빈 항목)"


def _digest(args: dict[str, Any]) -> str:
    raw = json.dumps(args, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(raw.encode()).hexdigest()


def _to_analysis_result(payload: dict[str, Any]) -> AnalysisResult:
    out = MultimodalAnalyzeOutput.model_validate(payload)
    primary = out.intent
    secondary = tuple(dict.fromkeys(s for s in out.secondary_intents if s != primary))
    return AnalysisResult(
        intent=primary,
        summary=out.summary,
        confidence=out.confidence,
        secondary_intents=secondary,
        intent_applicability={primary: out.confidence},
        importance=out.importance,
        model_version=out.model_version,
        entities=tuple(ExtractedEntity(kind=e.kind, value=e.value) for e in out.entities),
    )
