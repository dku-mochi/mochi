"""알림 전역 선호(0028) 발송 게이트 — off 스킵 / on 발송 / 기본값 on.

게이트는 발송 시점에만 있다: recall worker ``_send_one`` 서두(트랙 A/B/C 공용 send pass)와
분석 confirm push ``_notify_analysis_complete``. plan/outbox 적재는 불변(가역 밸브).
"""

from types import SimpleNamespace
from uuid import uuid4

import app.modules.agent.application.mochi_item_worker as mochi_item_worker_module
import app.modules.notifications.application.notification_worker as notification_worker_module
from app.modules.agent.application.mochi_item_worker import (
    MochiItemWorker,
    _analysis_push_enabled,
)
from app.modules.auth.domain.entities import User
from app.modules.auth.infrastructure.orm import UserRow
from app.modules.notifications.application.notification_worker import (
    ClaimedNotification,
    NotificationWorker,
)
from app.shared.ids import UserID


class _FakeResult:
    def __init__(self, value: bool | None) -> None:
        self._value = value

    def scalar_one_or_none(self) -> bool | None:
        return self._value


class _FakeSession:
    """선호 SELECT 1건만 응답하는 세션 겸 async context manager."""

    def __init__(self, pref: bool | None) -> None:
        self.pref = pref
        self.execute_calls = 0
        self.committed = False

    async def execute(self, stmt: object) -> _FakeResult:
        self.execute_calls += 1
        return _FakeResult(self.pref)

    async def commit(self) -> None:
        self.committed = True

    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *args: object) -> bool:
        return False


def _claimed(kind: str = "recall") -> ClaimedNotification:
    return ClaimedNotification(
        id=1,
        event_id=uuid4(),
        owner_id=uuid4(),
        kind=kind,
        title="t",
        body="b",
        source_item_id=None,
        source_intent_id=None,
        collapse_id=None,
        attempts=1,
    )


def test_notification_preferences_default_on() -> None:
    """기본값 둘 다 on — 도메인 entity 기본값 + ORM 컬럼 default 정합."""
    user = User(id=UserID(uuid4()), email="a@b.c")
    assert user.notify_recall_enabled is True
    assert user.notify_analysis_enabled is True
    assert UserRow.__table__.c.notify_recall_enabled.default.arg is True
    assert UserRow.__table__.c.notify_analysis_enabled.default.arg is True


async def test_send_one_skips_when_recall_pref_off(monkeypatch) -> None:
    worker = NotificationWorker()
    closed: dict[str, object] = {}

    async def fake_close(
        session_factory: object,
        outbox_id: int,
        *,
        status: str,
        skip_reason: str | None = None,
        last_error: str | None = None,
        set_sent_at: bool = False,
    ) -> None:
        closed.update(id=outbox_id, status=status, skip_reason=skip_reason)

    monkeypatch.setattr(worker, "_close", fake_close)
    session = _FakeSession(pref=False)
    # settings/apns 는 선호 게이트가 먼저 끊으므로 도달하지 않아야 한다 — None 으로 두어 검증.
    await worker._send_one(lambda: session, None, None, _claimed())
    assert closed == {"id": 1, "status": "skipped", "skip_reason": "preference_off"}
    assert session.execute_calls == 1  # 선호 SELECT 만 — 토큰 조회/발송 없음.


async def test_send_one_sends_when_recall_pref_on(monkeypatch) -> None:
    worker = NotificationWorker()
    closed: dict[str, object] = {}
    sent_to: list[object] = []

    async def fake_close(
        session_factory: object,
        outbox_id: int,
        *,
        status: str,
        skip_reason: str | None = None,
        last_error: str | None = None,
        set_sent_at: bool = False,
    ) -> None:
        closed.update(status=status, set_sent_at=set_sent_at)

    class _FakeSender:
        def __init__(self, *, tokens: object, apns: object) -> None:
            pass

        async def run(self, *, owner_id: object, notification: object) -> SimpleNamespace:
            sent_to.append(owner_id)
            return SimpleNamespace(sent=True, invalid_tokens=[], had_tokens=True, transient_error=None)

    monkeypatch.setattr(worker, "_close", fake_close)
    monkeypatch.setattr(notification_worker_module, "SendRecallNotification", _FakeSender)
    monkeypatch.setattr(notification_worker_module, "make_push_token_repository", lambda s: object())
    session = _FakeSession(pref=True)
    settings = SimpleNamespace(recall_notifications_dry_run=False)
    await worker._send_one(lambda: session, settings, object(), _claimed())
    assert len(sent_to) == 1
    assert closed == {"status": "sent", "set_sent_at": True}


async def test_analysis_push_enabled_only_false_is_off() -> None:
    owner = uuid4()
    assert await _analysis_push_enabled(_FakeSession(pref=True), owner) is True
    assert await _analysis_push_enabled(_FakeSession(pref=None), owner) is True  # 행 없음 → on 취급
    assert await _analysis_push_enabled(_FakeSession(pref=False), owner) is False


async def _run_notify_analysis(monkeypatch, *, pref: bool, needs_review: bool) -> list[object]:
    """`_notify_analysis_complete` 를 fake 배선으로 실행하고 SendAnalysisNotification.run 호출을 반환."""
    sent: list[object] = []
    session = _FakeSession(pref=pref)

    class _FakeGetItem:
        def __init__(self, *, repository: object) -> None:
            pass

        async def execute(self, *, owner_id: object, mochi_item_id: object) -> SimpleNamespace:
            return SimpleNamespace(needs_review=needs_review, summary="s", review_options=())

    class _FakeSender:
        def __init__(self, *, tokens: object, apns: object) -> None:
            pass

        async def run(self, *, owner_id: object, mochi_item_id: object, notification: object) -> None:
            sent.append(notification)

    monkeypatch.setattr(mochi_item_worker_module, "get_apns_client", lambda: object())
    monkeypatch.setattr(mochi_item_worker_module, "get_session_factory", lambda: (lambda: session))
    monkeypatch.setattr(mochi_item_worker_module, "make_mochi_item_repository", lambda s: object())
    monkeypatch.setattr(mochi_item_worker_module, "make_push_token_repository", lambda s: object())
    monkeypatch.setattr(mochi_item_worker_module, "GetMochiItemForOwner", _FakeGetItem)
    monkeypatch.setattr(mochi_item_worker_module, "SendAnalysisNotification", _FakeSender)
    worker = MochiItemWorker(max_steps=1)
    await worker._notify_analysis_complete(uuid4(), uuid4())
    return sent


async def test_notify_analysis_skips_when_pref_off(monkeypatch) -> None:
    sent = await _run_notify_analysis(monkeypatch, pref=False, needs_review=True)
    assert sent == []


async def test_notify_analysis_sends_when_pref_on(monkeypatch) -> None:
    sent = await _run_notify_analysis(monkeypatch, pref=True, needs_review=True)
    assert len(sent) == 1
