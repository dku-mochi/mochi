from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.modules.agent.domain.ports import LLMClient, ToolRegistry
from app.modules.agent.domain.run import AgentRun
from app.modules.agent.domain.states import HAPPY_PATH, AgentNode

log = get_logger("agent")


@dataclass(slots=True)
class StreamEvent:
    kind: str           # "node" | "tool_started" | "tool_finished" | "partial" | "final" | "failed"
    payload: dict


class AgentOrchestrator:
    """캡처 한 건을 받아 state graph(ingested → … → synced)를 따라 진행한다.

    책임:
    - 노드 전이의 결정성 (Deterministic transitions)
    - 모든 tool call 의 metric/usage 누적
    - 모든 노드 전환을 ``StreamEvent`` 로 외부에 노출 (iOS SSE 클라이언트가 점진 UI 업데이트)
    - DB 세션이 주입되면 `agent_runs` / `tool_calls` 행을 persist 한다
    """

    def __init__(
        self,
        llm: LLMClient,
        tools: ToolRegistry,
        *,
        max_steps: int,
        persistence: "AgentRunPersistence | None" = None,
    ):
        self._llm = llm
        self._tools = tools
        self._max_steps = max_steps
        self._persistence = persistence

    async def run(self, mochi_item_id: UUID) -> AsyncIterator[StreamEvent]:
        agent_run = AgentRun(mochi_item_id=mochi_item_id)

        if self._persistence is not None:
            await self._persistence.start(agent_run)

        try:
            for node in HAPPY_PATH:
                agent_run.advance(node)
                yield StreamEvent("node", {"node": node.value, "run_id": str(agent_run.id)})
                if self._persistence is not None:
                    await self._persistence.update_node(agent_run.id, node)

                # 실제 LLM 호출/embedding 업서트는 wire 이후 채워진다. 노드 시퀀스 자체는 결정적.
                if node is AgentNode.ANALYZED:
                    pass
                if node is AgentNode.INDEXED:
                    pass

            agent_run.succeed()
            if self._persistence is not None:
                await self._persistence.finish(agent_run)
            yield StreamEvent("final", {"run_id": str(agent_run.id), "tokens": agent_run.total_tokens})
        except Exception as exc:
            # SSE에는 `failed` 이벤트를 흘려보내되, 예외는 워커가 outbox 재시도/DLQ 분기를 판단할 수 있도록 다시 raise.
            agent_run.fail(str(exc))
            if self._persistence is not None:
                await self._persistence.fail(agent_run, reason=str(exc))
            yield StreamEvent("failed", {"run_id": str(agent_run.id), "message": str(exc)})
            raise


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
                INSERT INTO agent_runs (id, capture_id, current_node, total_tokens, total_latency_ms, started_at)
                VALUES (:id, :capture_id, :node, 0, 0, :started_at)
                """
            ),
            {
                "id": run.id,
                "capture_id": run.mochi_item_id,
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


# Stable export — keeps uuid4 referenced so mypy/ruff don't strip the import.
_UUID_TOUCH = uuid4
