"""SendRecallNotification 단위테스트 (P4) — payload 키 / 성공 / 410 무효 분류 / transient / no-op.

dead_letter·backoff 전이는 워커(NotificationWorker)의 결과 해석이라 여기선 SendRecallResult 분류만
검증한다(워커는 send 결과로 _close/_defer 한다 — integration). 정본 notification-agent.md §5 / codex-5.
"""

from uuid import uuid4

from app.modules.notifications.application.send_recall_notification import (
    RecallNotification,
    SendRecallNotification,
)
from app.modules.notifications.domain.entities import (
    APNsEnvironment,
    DevicePushToken,
    PushTokenType,
)
from app.modules.notifications.infrastructure.apns_client import APNsError


class _FakeAPNs:
    def __init__(self, *, fail_with: dict[str, APNsError] | None = None) -> None:
        self.sent: list[dict] = []
        self._fail_with = fail_with or {}  # token -> APNsError

    async def send(self, *, token, environment, push_type, topic, payload, collapse_id=None):
        if token in self._fail_with:
            raise self._fail_with[token]
        self.sent.append({"token": token, "topic": topic, "payload": payload, "collapse_id": collapse_id})


class _FakeRepo:
    def __init__(self, *, device=()) -> None:
        self._device = list(device)
        self.deleted: list[str] = []

    async def upsert(self, token):  # pragma: no cover
        ...

    async def list_for_owner(self, *, owner_id, token_type):
        return self._device if token_type == PushTokenType.APNS_DEVICE else []

    async def delete(self, *, token):
        self.deleted.append(token)


def _tok(owner, token="device-tok") -> DevicePushToken:
    return DevicePushToken(owner, token, PushTokenType.APNS_DEVICE, APNsEnvironment.SANDBOX)


def _notification(event_id=None, item=None, intent=None) -> RecallNotification:
    return RecallNotification(
        event_id=event_id or uuid4(),
        title="토익 시험",
        body="토익 시험 3일 남았어요",
        kind="deadline",
        source_item_id=item or uuid4(),
        source_intent_id=intent or uuid4(),
        collapse_id="collapse-1",
    )


async def test_success_sets_sent_and_payload_keys():
    owner = uuid4()
    event_id, item, intent = uuid4(), uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[_tok(owner)])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification(event_id=event_id, item=item, intent=intent)
    )
    assert result.sent is True
    assert result.had_tokens is True
    assert result.invalid_tokens == []
    payload = apns.sent[0]["payload"]
    # payload 키 정확(P5/P6 계약): recallEventID·kind·routeType·mochiItemID·sourceIntentID.
    assert payload["recallEventID"] == str(event_id)
    assert payload["kind"] == "deadline"
    assert payload["routeType"] == "detail"
    assert payload["mochiItemID"] == str(item)
    assert payload["sourceIntentID"] == str(intent)
    assert payload["aps"]["alert"]["title"] == "토익 시험"
    assert payload["aps"]["alert"]["body"] == "토익 시험 3일 남았어요"
    assert apns.sent[0]["collapse_id"] == "collapse-1"


async def test_410_marks_token_invalid_and_not_sent():
    owner = uuid4()
    apns = _FakeAPNs(fail_with={"bad-tok": APNsError("gone", status_code=410, reason="Unregistered")})
    repo = _FakeRepo(device=[_tok(owner, "bad-tok")])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification()
    )
    assert result.sent is False
    assert result.invalid_tokens == ["bad-tok"]
    assert result.transient_error is None


async def test_bad_device_token_reason_marks_invalid():
    owner = uuid4()
    apns = _FakeAPNs(fail_with={"bad-tok": APNsError("bad", status_code=400, reason="BadDeviceToken")})
    repo = _FakeRepo(device=[_tok(owner, "bad-tok")])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification()
    )
    assert result.invalid_tokens == ["bad-tok"]


async def test_invalid_token_then_valid_token_still_sends():
    owner = uuid4()
    apns = _FakeAPNs(fail_with={"bad": APNsError("gone", status_code=410, reason="Unregistered")})
    repo = _FakeRepo(device=[_tok(owner, "bad"), _tok(owner, "good")])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification()
    )
    assert result.sent is True
    assert result.invalid_tokens == ["bad"]
    assert len(apns.sent) == 1
    assert apns.sent[0]["token"] == "good"


async def test_5xx_is_transient_not_invalid():
    owner = uuid4()
    apns = _FakeAPNs(fail_with={"t": APNsError("server", status_code=503, reason="InternalServerError")})
    repo = _FakeRepo(device=[_tok(owner, "t")])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification()
    )
    assert result.sent is False
    assert result.invalid_tokens == []
    assert result.transient_error is not None


async def test_no_tokens_had_tokens_false():
    owner = uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[])
    result = await SendRecallNotification(tokens=repo, apns=apns).run(
        owner_id=owner, notification=_notification()
    )
    assert result.had_tokens is False
    assert result.sent is False


async def test_apns_none_is_noop():
    owner = uuid4()
    repo = _FakeRepo(device=[_tok(owner)])
    result = await SendRecallNotification(tokens=repo, apns=None).run(
        owner_id=owner, notification=_notification()
    )
    assert result.sent is False
    assert result.had_tokens is False


async def test_payload_omits_deeplink_when_none():
    owner = uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[_tok(owner)])
    n = RecallNotification(
        event_id=uuid4(),
        title="t",
        body="b",
        kind="recall",
        source_item_id=None,
        source_intent_id=None,
        collapse_id=None,
    )
    await SendRecallNotification(tokens=repo, apns=apns).run(owner_id=owner, notification=n)
    payload = apns.sent[0]["payload"]
    assert "mochiItemID" not in payload
    assert "sourceIntentID" not in payload
    assert payload["recallEventID"]  # 항상 존재(반응 추적)
