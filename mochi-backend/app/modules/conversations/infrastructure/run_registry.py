"""in-process run 이벤트 중계 — 생성(detached task)과 전달(SSE 응답)의 분리 지점.

Redis 불사용(확정, journal 2026-06-10): 단일 인스턴스 전제, 서버 재시작 시 진행 run 유실은
감수(읽기 시점 lazy stale repair 가 줍는다). 단일 구독자 전제 — 재접속은 스냅샷 재조회.

큐는 unbounded 지만 run 수명(60s 상한) 동안만 쌓이고 close 시 레지스트리에서 제거된다.
"""

import asyncio
from functools import lru_cache
from uuid import UUID

from app.modules.conversations.domain.run_events import ChatEvent

#: 스트림 종료 sentinel — close() 가 넣는다.
_CLOSE = None


class RunRegistry:
    def __init__(self) -> None:
        self._queues: dict[UUID, asyncio.Queue[ChatEvent | None]] = {}

    def create(self, run_id: UUID) -> "asyncio.Queue[ChatEvent | None]":
        queue: asyncio.Queue[ChatEvent | None] = asyncio.Queue()
        self._queues[run_id] = queue
        return queue

    def publish(self, run_id: UUID, event: ChatEvent) -> None:
        """구독 큐가 이미 닫혔으면 조용히 버린다 — 전달은 best-effort, 영속이 진실원천."""
        queue = self._queues.get(run_id)
        if queue is not None:
            queue.put_nowait(event)

    def close(self, run_id: UUID) -> None:
        queue = self._queues.pop(run_id, None)
        if queue is not None:
            queue.put_nowait(_CLOSE)


@lru_cache(maxsize=1)
def get_run_registry() -> RunRegistry:
    return RunRegistry()
