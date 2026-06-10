"""Conversations hexagonal outbound ports.

모든 메서드가 ``owner_id`` 를 키워드로 강제한다 — cross-tenant 누설 방지 (기존 repository 규약).
"""

from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Protocol
from uuid import UUID

from app.modules.conversations.domain.entities import Conversation, Message, RunStatus


class ConversationRepository(Protocol):
    async def create(self, *, owner_id: UUID, conversation: Conversation) -> None: ...

    async def find_by_id(self, *, owner_id: UUID, conversation_id: UUID) -> Conversation | None:
        """soft delete 된 대화는 None. owner-scoped."""
        ...

    async def list_for_owner(self, *, owner_id: UUID, limit: int) -> list[Conversation]:
        """updated_at 내림차순, deleted 제외. 히스토리 시트의 데이터 소스."""
        ...

    async def soft_delete(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        """deleted_at 마킹(행·메시지 보존). 없거나 다른 owner 면 False (→ 404)."""
        ...

    async def add_message(self, *, owner_id: UUID, message: Message) -> bool:
        """메시지(citations 포함) append + 대화 updated_at bump (히스토리 정렬 소스).

        대화가 없거나·soft delete 됐거나·다른 owner 면 **아무것도 쓰지 않고 False** —
        cross-tenant 쓰기·고아 행 차단.
        """
        ...

    async def list_messages(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]:
        """대화의 전체 메시지(citations 포함)를 created_at 오름차순으로. 스냅샷 재조회용."""
        ...

    async def mark_stale_runs_failed(
        self, *, owner_id: UUID, conversation_id: UUID, started_before: datetime
    ) -> int:
        """``started_before`` 이전에 시작해 아직 running 인 run 을 failed 로 lazy repair.

        서버 재시작으로 in-process run 이 유실되면 행이 running 으로 영원히 남는다 —
        스케줄러 없이 스냅샷 읽기 시점에 줍는다. 갱신된 행 수 반환.
        """
        ...

    async def has_running_run(self, *, owner_id: UUID, conversation_id: UUID) -> bool:
        """대화에 진행 중 run 존재 여부 — 동일 대화 동시 run 차단(409)용.

        호출 전 ``mark_stale_runs_failed`` 로 stale 을 정리하고 부르는 것이 계약이다.
        """
        ...

    async def set_run_status(self, *, owner_id: UUID, run_id: UUID, status: RunStatus) -> bool:
        """run 을 트리거한 user message 행의 run_status 갱신. 없으면 False."""
        ...


# ---------- 채팅 run (agent loop) ----------


@dataclass(frozen=True, slots=True)
class ChatToolResult:
    """툴 실행 결과 — 모델에 돌려줄 payload + 사용자에게 보여줄 1줄.

    - ``compact``: 과거 턴 히스토리 재구성용 축약본(상위 일부 id·제목) — tool result 가
      토큰의 대부분이라, 현재 턴만 ``payload`` 풀 버전을 쓰고 지난 턴은 이것으로 접는다.
    - ``proposal``: propose_* 툴이 채우는 확인 카드 ``{id, type, payload}``. **DB 쓰기 없음** —
      run 루프가 SSE ``proposal`` 이벤트로 흘리고 assistant 행 ``proposals`` 에 영속만 한다.
      실행은 사용자 확정 탭 → REST.
    """

    payload: dict[str, Any]
    summary: str
    compact: dict[str, Any] = field(default_factory=dict)
    proposal: dict[str, Any] | None = None


class ChatTool(Protocol):
    """채팅 툴 — **DB 쓰기 금지** (LLM 루프는 read-only, 쓰기는 proposal 카드).

    proposal 툴(PR-3)도 이 인터페이스로: 검증 후 proposal payload 를 *반환*할 뿐 실행하지 않는다.
    """

    name: str
    label: str          # tool_started 동사형 카피 — "기록을 뒤지고 있어요"
    description: str    # 모델용 (영어)
    parameters: dict[str, Any]   # JSON Schema

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult: ...


@dataclass(frozen=True, slots=True)
class ChatLLMChunk:
    """채팅 LLM 스트림 단위 — 텍스트 델타 또는 함수 호출."""

    text_delta: str | None = None
    tool_call: tuple[str, dict[str, Any]] | None = None
    thought_signature: bytes | None = None


class ChatLLMClient(Protocol):
    """한 라운드의 LLM 호출 — function-calling AUTO + 텍스트 스트리밍.

    기존 ``agent.domain.ports.LLMClient`` 는 finalize 전용(mode=ANY, 스트림 없음)이라
    재사용 불가 — 채팅 전용 포트를 분리한다.
    """

    def stream(
        self,
        *,
        system_prompt: str,
        contents: list[dict[str, Any]],
        tools: list[ChatTool],
    ) -> AsyncIterator[ChatLLMChunk]: ...


@dataclass(frozen=True, slots=True)
class ResolvedCitation:
    """본문 마커의 item id 를 owner-scoped 로 실재 검증한 결과."""

    mochi_item_id: UUID
    title: str | None
    snippet: str | None


class ChatTurnStore(Protocol):
    """run(detached task)의 영속 작업 묶음.

    request 세션을 쓸 수 없는 detached task 가 **연산마다 자체 세션**을 열고 즉시 commit
    하도록, 세션 수명을 구현 뒤에 숨긴다(클라 이탈·서버 죽음에도 단계별 영속 보장).
    """

    async def load_history(self, *, owner_id: UUID, conversation_id: UUID) -> list[Message]: ...

    async def append(self, *, owner_id: UUID, message: Message) -> bool: ...

    async def set_run_status(self, *, owner_id: UUID, run_id: UUID, status: RunStatus) -> bool: ...

    async def resolve_citations(
        self, *, owner_id: UUID, mochi_item_ids: list[UUID]
    ) -> list[ResolvedCitation]:
        """owner 소유로 실재하는 id 만, 입력 순서를 보존해 반환 (미실재·타인 소유는 누락)."""
        ...
