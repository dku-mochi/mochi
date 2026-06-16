"""능동 회수 알림 push 전송 — SendAnalysisNotification 형제 (P4).

워커(NotificationWorker)가 materialize 된 outbox 1건을 이 use case 로 발송한다. owner 의
apns_device 토큰들에 alert push 를 best-effort(토큰별)로 쏘고, **실패 분류 결과**를 호출부에
돌려준다(codex-5) — 410/Unregistered/BadDeviceToken 은 invalid_tokens, 5xx/timeout 은 transient.
호출부(워커)가 invalid 토큰 무효화·sent/dead_letter/pending 전이를 결정한다.

payload(notification-agent.md §5): aps.alert + mochiItemID + sourceIntentID + routeType + recallEventID
+ kind. collapse_id 는 호출부가 outbox 에서 넘긴다(기존대로).
"""

from dataclasses import dataclass, field
from uuid import UUID

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.notifications.domain.entities import APNsPushType, PushTokenType
from app.modules.notifications.domain.ports import APNsClient, PushTokenRepository
from app.modules.notifications.infrastructure.apns_client import APNsError

log = get_logger("notifications.send_recall")

_ALERT_BODY_MAX = 178
# 알림 탭 → 단건 상세 직행(ux-ui.md §4). list 분기는 트랙 C 묶기 후속이라 지금은 detail 고정.
_ROUTE_TYPE_DETAIL = "detail"

# APNs 영구 실패 reason — 토큰 무효화 대상(codex-5). 410 status_code 도 영구로 본다.
_INVALID_TOKEN_REASONS = frozenset({"Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"})


@dataclass(frozen=True, slots=True)
class RecallNotification:
    """발송할 회수 알림 1건 (워커가 outbox row 에서 구성)."""

    event_id: UUID
    title: str
    body: str
    kind: str  # deadline | nudge | spaced | recall
    source_item_id: UUID | None
    source_intent_id: UUID | None
    collapse_id: str | None


@dataclass(slots=True)
class SendRecallResult:
    """발송 분류 결과 — 호출부(워커)가 outbox 전이를 결정한다.

    - sent: 적어도 한 토큰에 200 성공.
    - invalid_tokens: 무효화(삭제) 대상 토큰(410/Unregistered/BadDeviceToken).
    - transient_error: 5xx/timeout 류 transient 실패 메시지(있으면 backoff 재시도 후보).
    - had_tokens: owner 에게 device 토큰이 하나라도 있었나(0이면 no_valid_token).
    """

    sent: bool = False
    invalid_tokens: list[str] = field(default_factory=list)
    transient_error: str | None = None
    had_tokens: bool = False


class SendRecallNotification:
    def __init__(self, *, tokens: PushTokenRepository, apns: APNsClient | None) -> None:
        self._tokens = tokens
        self._apns = apns

    async def run(self, *, owner_id: UUID, notification: RecallNotification) -> SendRecallResult:
        result = SendRecallResult()
        if self._apns is None:
            return result  # APNs 미설정(local dev) — no-op. 워커가 had_tokens=False 로 skip 처리.

        bundle_id = get_settings().apns_bundle_id
        payload = self._build_payload(notification)
        device_tokens = await self._tokens.list_for_owner(
            owner_id=owner_id, token_type=PushTokenType.APNS_DEVICE
        )
        result.had_tokens = len(device_tokens) > 0
        log.info(
            "recall.send_targets",
            owner_id=str(owner_id),
            event_id=str(notification.event_id),
            kind=notification.kind,
            count=len(device_tokens),
        )
        for tok in device_tokens:
            try:
                await self._apns.send(
                    token=tok.token,
                    environment=tok.environment,
                    push_type=APNsPushType.ALERT,
                    topic=bundle_id,
                    payload=payload,
                    collapse_id=notification.collapse_id,
                )
                result.sent = True
                log.info(
                    "recall.send_sent",
                    owner_id=str(owner_id),
                    event_id=str(notification.event_id),
                    token=_mask_token(tok.token),
                )
            except APNsError as exc:
                if _is_invalid_token(exc):
                    result.invalid_tokens.append(tok.token)
                    log.info(
                        "recall.send_invalid_token",
                        owner_id=str(owner_id),
                        event_id=str(notification.event_id),
                        token=_mask_token(tok.token),
                        status_code=exc.status_code,
                        reason=exc.reason,
                    )
                else:
                    result.transient_error = str(exc)
                    log.warning(
                        "recall.send_transient",
                        owner_id=str(owner_id),
                        event_id=str(notification.event_id),
                        token=_mask_token(tok.token),
                        status_code=exc.status_code,
                        exception=str(exc),
                    )
            except Exception as exc:  # noqa: BLE001 - 네트워크/timeout 등 transient
                result.transient_error = str(exc)
                log.warning(
                    "recall.send_transient",
                    owner_id=str(owner_id),
                    event_id=str(notification.event_id),
                    token=_mask_token(tok.token),
                    exception=str(exc),
                    exc_info=True,
                )
        return result

    @staticmethod
    def _build_payload(n: RecallNotification) -> dict[str, object]:
        payload: dict[str, object] = {
            "aps": {
                "alert": {"title": n.title, "body": n.body[:_ALERT_BODY_MAX]},
                "sound": "default",
            },
            "recallEventID": str(n.event_id),  # 반응 추적(P5 opened/dismissed 보고 키)
            "routeType": _ROUTE_TYPE_DETAIL,
            "kind": n.kind,  # 빌더 분기(iOS landing 섹션)
        }
        # 딥링크 — 로컬 역매핑 후보(없으면 iOS 가 recallEventID 로 서버 landing fetch, codex-2).
        if n.source_item_id is not None:
            payload["mochiItemID"] = str(n.source_item_id)
        if n.source_intent_id is not None:
            payload["sourceIntentID"] = str(n.source_intent_id)
        return payload


def _is_invalid_token(exc: APNsError) -> bool:
    if exc.status_code == 410:
        return True
    return exc.reason in _INVALID_TOKEN_REASONS


def _mask_token(token: str) -> str:
    if len(token) <= 14:
        return f"{token[:4]}...{token[-4:]}"
    return f"{token[:8]}...{token[-6:]}"
