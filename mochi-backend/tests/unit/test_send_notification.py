"""SendAnalysisNotification 단위 테스트 — alert 분기, LA content-state, 4KB 가드, apns no-op."""

import json
from uuid import UUID, uuid4

from app.modules.mochi_items.domain.value_objects import ReviewOption
from app.modules.notifications.application.send_notification import (
    AnalysisNotification,
    SendAnalysisNotification,
)
from app.modules.notifications.domain.entities import (
    APNsEnvironment,
    APNsPushType,
    DevicePushToken,
    PushTokenType,
)
from app.shared.intent import Intent


class _FakeAPNs:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send(self, *, token, environment, push_type, topic, payload, collapse_id=None):
        self.sent.append(
            {"token": token, "push_type": push_type, "topic": topic, "payload": payload}
        )


class _FakeRepo:
    def __init__(self, *, device=(), live_activity=()) -> None:
        self._device = list(device)
        self._la = list(live_activity)

    async def upsert(self, token):  # pragma: no cover - 미사용
        ...

    async def list_for_owner(self, *, owner_id, token_type):
        return self._device if token_type == PushTokenType.APNS_DEVICE else []

    async def list_live_activity_for_item(self, *, owner_id, mochi_item_id):
        return self._la


def _device_token(owner: UUID) -> DevicePushToken:
    return DevicePushToken(owner, "device-tok", PushTokenType.APNS_DEVICE, APNsEnvironment.SANDBOX)


def _la_token(owner: UUID, item: UUID) -> DevicePushToken:
    return DevicePushToken(
        owner, "la-tok", PushTokenType.LIVE_ACTIVITY, APNsEnvironment.SANDBOX, mochi_item_id=item
    )


async def test_complete_alert_when_not_needs_review():
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[_device_token(owner)])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=False, summary="회의 일정 저장", review_options=()),
    )
    assert len(apns.sent) == 1
    sent = apns.sent[0]
    assert sent["push_type"] == APNsPushType.ALERT
    assert sent["payload"]["aps"]["alert"]["title"] == "이렇게 저장했어요"
    assert "회의 일정 저장" in sent["payload"]["aps"]["alert"]["body"]
    assert sent["payload"]["mochiItemID"] == str(item)


async def test_review_alert_when_needs_review():
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[_device_token(owner)])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="뭐였더라", review_options=()),
    )
    assert apns.sent[0]["payload"]["aps"]["alert"]["title"] == "어떤 의도로 남겼나요?"


async def test_live_activity_push_carries_ready_phase_and_candidates():
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(live_activity=[_la_token(owner, item)])
    options = (
        ReviewOption(intent_type=Intent.TODO, label="구매 고민", reasoning="살까 말까"),
        ReviewOption(intent_type=Intent.MEMO, label="그냥 메모", reasoning="기록"),
    )
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="s", review_options=options),
    )
    la = [s for s in apns.sent if s["push_type"] == APNsPushType.LIVEACTIVITY]
    assert len(la) == 1
    assert la[0]["topic"].endswith(".push-type.liveactivity")
    cs = la[0]["payload"]["aps"]["content-state"]
    assert cs["phase"] == "ready"
    assert cs["needsReview"] is True
    assert len(cs["candidates"]) == 2
    assert cs["candidates"][0]["intentType"] == Intent.TODO.value


async def test_live_activity_candidate_label_is_never_null():
    # ReviewOption.label 은 str|None 이지만 LA push 의 candidate label 은 non-null 이어야 한다 —
    # iOS Candidate.label 이 비옵셔널이라 null 이면 content-state decode 가 throw(background LA 무음 드롭).
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(live_activity=[_la_token(owner, item)])
    options = (ReviewOption(intent_type=Intent.SCHEDULE, label=None, reasoning=""),)
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="s", review_options=options),
    )
    cs = apns.sent[0]["payload"]["aps"]["content-state"]
    assert cs["candidates"][0]["label"] == Intent.SCHEDULE.value  # null → intent_type fallback
    assert cs["candidates"][0]["label"] is not None


async def test_live_activity_payload_within_4kb():
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(live_activity=[_la_token(owner, item)])
    huge = tuple(
        ReviewOption(intent_type=Intent.TODO, label="x" * 80, reasoning="아주 긴 이유 " * 200)
        for _ in range(10)
    )
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="요약" * 100, review_options=huge),
    )
    payload = apns.sent[0]["payload"]
    assert len(json.dumps(payload, ensure_ascii=False).encode()) <= 4096


async def test_apns_none_is_noop():
    owner, item = uuid4(), uuid4()
    repo = _FakeRepo(device=[_device_token(owner)])
    # apns=None 이면 토큰이 있어도 전송 시도 없음(예외 없이 통과).
    await SendAnalysisNotification(tokens=repo, apns=None).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=False, summary="x", review_options=()),
    )
