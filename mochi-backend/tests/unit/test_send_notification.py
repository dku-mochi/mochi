"""SendAnalysisNotification 단위 테스트 — alert 분기, LA push-to-start, 4KB 가드, apns no-op."""

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
from app.modules.notifications.infrastructure.apns_client import APNsError
from app.shared.intent import Intent


class _FakeAPNs:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send(self, *, token, environment, push_type, topic, payload, collapse_id=None):
        self.sent.append({"token": token, "push_type": push_type, "topic": topic, "payload": payload})


class _FakeRepo:
    def __init__(self, *, device=(), la_start=()) -> None:
        self._device = list(device)
        self._la_start = list(la_start)
        self.deleted: list[str] = []

    async def upsert(self, token):  # pragma: no cover - 미사용
        ...

    async def list_for_owner(self, *, owner_id, token_type):
        if token_type == PushTokenType.APNS_DEVICE:
            return self._device
        if token_type == PushTokenType.LA_START:
            return self._la_start
        return []

    async def delete(self, *, token):
        self.deleted.append(token)


def _device_token(owner: UUID) -> DevicePushToken:
    return DevicePushToken(owner, "device-tok", PushTokenType.APNS_DEVICE, APNsEnvironment.SANDBOX)


def _la_start_token(owner: UUID) -> DevicePushToken:
    # push-to-start 토큰은 owner 단위(item 무관) — mochi_item_id 없음.
    return DevicePushToken(owner, "la-start-tok", PushTokenType.LA_START, APNsEnvironment.SANDBOX)


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


async def test_no_la_start_when_not_needs_review():
    # 완료(needs_review=false)는 alert 만 — LA push-to-start 는 보내지 않는다(팀 결정 2026-06-09).
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(device=[_device_token(owner)], la_start=[_la_start_token(owner)])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=False, summary="저장됨", review_options=()),
    )
    assert all(s["push_type"] != APNsPushType.LIVEACTIVITY for s in apns.sent)
    assert len([s for s in apns.sent if s["push_type"] == APNsPushType.ALERT]) == 1


async def test_la_start_push_carries_attributes_and_content_state():
    # needs_review=true 면 owner 의 push-to-start 토큰으로 LA 를 시작(event=start)한다.
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(la_start=[_la_start_token(owner)])
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
    aps = la[0]["payload"]["aps"]
    # start push: attributes(불변 초기값) + content-state 를 함께 싣는다.
    assert aps["event"] == "start"
    assert aps["attributes-type"] == "MochiLiveActivityAttributes"
    assert aps["attributes"]["mochiItemID"] == str(item)
    assert aps["attributes"]["thumbnailRelativePath"] is None  # 백엔드는 로컬경로를 모름 → placeholder
    cs = aps["content-state"]
    assert cs["phase"] == "ready"
    assert cs["needsReview"] is True
    assert len(cs["candidates"]) == 2
    assert cs["candidates"][0]["intentType"] == Intent.TODO.value


async def test_la_start_candidate_label_is_never_null():
    # ReviewOption.label 은 str|None 이지만 candidate label 은 non-null 이어야 한다 —
    # iOS Candidate.label 이 비옵셔널이라 null 이면 content-state decode 가 throw(start 무음 드롭).
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(la_start=[_la_start_token(owner)])
    options = (ReviewOption(intent_type=Intent.SCHEDULE, label=None, reasoning=""),)
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="s", review_options=options),
    )
    cs = apns.sent[0]["payload"]["aps"]["content-state"]
    assert cs["candidates"][0]["label"] == Intent.SCHEDULE.value  # null → intent_type fallback
    assert cs["candidates"][0]["label"] is not None


async def test_la_start_payload_within_4kb():
    owner, item = uuid4(), uuid4()
    apns = _FakeAPNs()
    repo = _FakeRepo(la_start=[_la_start_token(owner)])
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


class _FailingAPNs:
    """지정 토큰에 APNsError 를 던지는 fake — 토큰 무효화 분기 검증용."""

    def __init__(self, *, fail_tokens, status_code=410, reason="Unregistered") -> None:
        self.sent: list[dict] = []
        self._fail = set(fail_tokens)
        self._status_code = status_code
        self._reason = reason

    async def send(self, *, token, environment, push_type, topic, payload, collapse_id=None):
        if token in self._fail:
            raise APNsError("apns failure", status_code=self._status_code, reason=self._reason)
        self.sent.append({"token": token})


async def test_alert_410_invalidates_token():
    # 410/Unregistered alert 실패 → 죽은 토큰 무효화(삭제). 앱 재설치 누적 토큰 정리.
    owner, item = uuid4(), uuid4()
    dead = DevicePushToken(owner, "dead-device", PushTokenType.APNS_DEVICE, APNsEnvironment.SANDBOX)
    apns = _FailingAPNs(fail_tokens={"dead-device"})
    repo = _FakeRepo(device=[dead])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=False, summary="x", review_options=()),
    )
    assert repo.deleted == ["dead-device"]


async def test_la_start_410_invalidates_token():
    # 410 LA push-to-start 실패 → 죽은 토큰 무효화(매번 재발송되던 문제 해결).
    owner, item = uuid4(), uuid4()
    dead = DevicePushToken(owner, "dead-la", PushTokenType.LA_START, APNsEnvironment.SANDBOX)
    apns = _FailingAPNs(fail_tokens={"dead-la"})
    repo = _FakeRepo(la_start=[dead])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=True, summary="x", review_options=()),
    )
    assert repo.deleted == ["dead-la"]


async def test_transient_5xx_does_not_invalidate_token():
    # 5xx/timeout 은 일시 실패 — 토큰을 무효화하지 않는다(다음 재시도 대상).
    owner, item = uuid4(), uuid4()
    tok = DevicePushToken(owner, "live-device", PushTokenType.APNS_DEVICE, APNsEnvironment.SANDBOX)
    apns = _FailingAPNs(fail_tokens={"live-device"}, status_code=503, reason=None)
    repo = _FakeRepo(device=[tok])
    await SendAnalysisNotification(tokens=repo, apns=apns).run(
        owner_id=owner,
        mochi_item_id=item,
        notification=AnalysisNotification(needs_review=False, summary="x", review_options=()),
    )
    assert repo.deleted == []
