"""NotificationWorker.`_maybe_decay_knowledge` — knowledge 시간 전이 패스(트랙A 무력 해소, 리뷰 HIGH-2).

전이 합법성은 `test_lifecycle_policy.test_knowledge_can_decay_then_review_requested` 가 고정한다.
여기서는 DB 없이 (1) 하루 1회 throttle, (2) due 일 때 2개 UPDATE 발행 + 시각 기록을 검증한다.
"""

from datetime import UTC, datetime, timedelta

import pytest

from app.modules.notifications.application.notification_worker import NotificationWorker


class _FakeResult:
    rowcount = 0


class _FakeSession:
    def __init__(self) -> None:
        self.executed: list[object] = []
        self.committed = False

    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def execute(self, stmt: object) -> _FakeResult:
        self.executed.append(stmt)
        return _FakeResult()

    async def commit(self) -> None:
        self.committed = True


class _FakeFactory:
    def __init__(self) -> None:
        self.created = 0
        self.session = _FakeSession()

    def __call__(self) -> _FakeSession:
        self.created += 1
        return self.session


@pytest.mark.asyncio
async def test_decay_throttled_within_interval() -> None:
    worker = NotificationWorker()
    worker._last_decay_at = datetime.now(UTC)  # 방금 돌았음
    factory = _FakeFactory()
    await worker._maybe_decay_knowledge(factory)  # type: ignore[arg-type]
    assert factory.created == 0  # 세션 안 염 = 스킵


@pytest.mark.asyncio
async def test_decay_runs_when_due_and_issues_two_updates() -> None:
    worker = NotificationWorker()
    worker._last_decay_at = datetime.now(UTC) - timedelta(days=2)  # 하루 넘게 안 돌았음
    factory = _FakeFactory()
    await worker._maybe_decay_knowledge(factory)  # type: ignore[arg-type]
    assert factory.created == 1
    assert len(factory.session.executed) == 2  # active→decaying, decaying→reviewRequested
    assert factory.session.committed is True
    assert worker._last_decay_at is not None


@pytest.mark.asyncio
async def test_decay_runs_on_first_pass() -> None:
    worker = NotificationWorker()  # _last_decay_at=None
    factory = _FakeFactory()
    await worker._maybe_decay_knowledge(factory)  # type: ignore[arg-type]
    assert factory.created == 1
