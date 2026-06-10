"""채팅(질문 탭) 도메인 엔티티 — Conversation · Message · MessageCitation.

설계 정본: ``journal/2026-06-10-chat-tab-design.md`` (proposal 패턴 — LLM 루프는 read-only,
쓰기는 proposal 카드 → 사용자 확정 → 기존 REST). 대화는 서버 단일원천(iOS Realm 미러 없음).

run 영속은 별도 테이블 없이 **트리거한 user message 행**에 ``run_id/run_status/run_started_at``
으로 싣는다 — turn 당 run 1개라 자연스럽고, stale 판정(읽기 시점 lazy repair)까지 컬럼 3개로 끝난다.
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any
from uuid import UUID, uuid4

#: 첫 user 메시지에서 잘라 만드는 자동 제목 길이 (LLM 요약 안 씀 — 호출 1회 절약).
TITLE_MAX_CHARS = 40

#: run_started_at 이 이보다 오래된 running run 은 읽기 시점에 failed 로 lazy repair.
#: run 자체 타임아웃(60s) + 마진. 서버 재시작으로 in-process run 이 유실된 경우를 줍는다.
STALE_RUN_SECONDS = 90


class MessageRole(StrEnum):
    USER = "user"
    ASSISTANT = "assistant"
    TOOL = "tool"


class RunStatus(StrEnum):
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


def title_from_first_message(text: str) -> str:
    """대화 자동 제목 = 첫 user 메시지 1줄 truncate."""
    first_line = text.strip().splitlines()[0] if text.strip() else ""
    if len(first_line) <= TITLE_MAX_CHARS:
        return first_line
    return first_line[: TITLE_MAX_CHARS - 1] + "…"


@dataclass(slots=True)
class Conversation:
    """대화 세션. soft delete(deleted_at) — repository 조회가 가린다."""

    id: UUID
    title: str | None = None
    created_at: datetime = field(default_factory=datetime.utcnow)
    updated_at: datetime = field(default_factory=datetime.utcnow)


@dataclass(frozen=True, slots=True)
class MessageCitation:
    """답변이 인용한 MochiItem 의 출처 스냅샷.

    mochi_item_id 에 FK 를 걸지 않는다 — item 이 삭제돼도 "그때 무엇을 근거로 답했나"
    (title/snippet 스냅샷)는 보존한다.
    """

    mochi_item_id: UUID
    citation_index: int
    title: str | None = None
    snippet: str | None = None
    id: UUID = field(default_factory=uuid4)


@dataclass(slots=True)
class Message:
    """대화의 한 행 — user 발화 / assistant 답변 / tool 실행 기록.

    - ``content``: user/assistant 텍스트. assistant 는 ``【item:id】`` citation 마커 원문을
      보존 저장한다(스냅샷 재조회 시 iOS 가 SSE 때와 동일하게 치환).
    - ``tool_name``/``tool_payload``: role=tool 행. payload 는 {args, summary, result_truncated}.
    - ``proposals``: role=assistant 행에 실리는 proposal 카드 배열 (typed 스키마는 PR-3).
    - ``run_*``: role=user 행에만 — 이 발화가 트리거한 agent run 의 상태.
    """

    id: UUID
    conversation_id: UUID
    role: MessageRole
    content: str | None = None
    tool_name: str | None = None
    tool_payload: dict[str, Any] | None = None
    proposals: tuple[dict[str, Any], ...] = ()
    run_id: UUID | None = None
    run_status: RunStatus | None = None
    run_started_at: datetime | None = None
    citations: tuple[MessageCitation, ...] = ()
    created_at: datetime = field(default_factory=datetime.utcnow)
