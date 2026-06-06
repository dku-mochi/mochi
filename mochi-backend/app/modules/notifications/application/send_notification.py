"""분석완료 push 전송 — alert(전 단말) + Live Activity .ready 전환(해당 item).

worker(outbox)가 분석결과를 ``AnalysisNotification`` 으로 넘긴다 — notifications 모듈은
mochi_items 를 직접 조회하지 않는다(모듈 경계). ReviewOption/Intent 는 타 모듈 domain 이라 허용.

push 는 best-effort 다 — 호출부(worker)가 예외를 격리한다. 여기서는 전송 책임만 진다.
"""

import json
import time
from dataclasses import dataclass
from uuid import UUID

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.mochi_items.domain.value_objects import ReviewOption
from app.modules.notifications.domain.entities import APNsPushType, PushTokenType
from app.modules.notifications.domain.ports import APNsClient, PushTokenRepository

log = get_logger("notifications.send")

# Live Activity content-state 는 APNs payload 4KB 상한에 묶인다. 후보 reasoning 이 길면 truncate.
_LA_PAYLOAD_MAX_BYTES = 4096
# iOS 알림 본문은 길면 OS 가 truncate — 1줄 요약 상한.
_ALERT_BODY_MAX = 178


@dataclass(frozen=True, slots=True)
class AnalysisNotification:
    """분석완료 시점에 push 로 보낼 내용 (worker 가 mochi_item 에서 추출해 구성)."""

    needs_review: bool
    summary: str | None
    review_options: tuple[ReviewOption, ...]


class SendAnalysisNotification:
    def __init__(self, *, tokens: PushTokenRepository, apns: APNsClient | None) -> None:
        self._tokens = tokens
        self._apns = apns

    async def run(
        self, *, owner_id: UUID, mochi_item_id: UUID, notification: AnalysisNotification
    ) -> None:
        if self._apns is None:
            return  # APNs 미설정(local dev) — no-op.

        bundle_id = get_settings().apns_bundle_id

        # 1) alert push — owner 의 모든 단말. needs_review 분기 문구.
        # 토큰별 격리 — stale token 1개 실패가 나머지 단말·LA 전송을 막지 않게(best-effort 단위 축소).
        alert_payload = self._build_alert(mochi_item_id, notification)
        device_tokens = await self._tokens.list_for_owner(
            owner_id=owner_id, token_type=PushTokenType.APNS_DEVICE
        )
        log.info(
            "push.alert_targets",
            owner_id=str(owner_id),
            mochi_item_id=str(mochi_item_id),
            count=len(device_tokens),
            needs_review=notification.needs_review,
        )
        for tok in device_tokens:
            try:
                await self._apns.send(
                    token=tok.token,
                    environment=tok.environment,
                    push_type=APNsPushType.ALERT,
                    topic=bundle_id,
                    payload=alert_payload,
                    collapse_id=str(mochi_item_id),
                )
                log.info(
                    "push.alert_sent",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    token=_mask_token(tok.token),
                    environment=tok.environment.value,
                )
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "push.alert_failed",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    token=_mask_token(tok.token),
                    environment=tok.environment.value,
                    exception=str(exc),
                    exc_info=True,
                )

        # 2) Live Activity push — 이 item 의 LA 토큰. analyzing→ready 전환(전 채널).
        la_payload = self._build_live_activity(notification)
        live_activity_tokens = await self._tokens.list_live_activity_for_item(
            owner_id=owner_id, mochi_item_id=mochi_item_id
        )
        log.info(
            "push.la_targets",
            owner_id=str(owner_id),
            mochi_item_id=str(mochi_item_id),
            count=len(live_activity_tokens),
            needs_review=notification.needs_review,
        )
        for tok in live_activity_tokens:
            try:
                await self._apns.send(
                    token=tok.token,
                    environment=tok.environment,
                    push_type=APNsPushType.LIVEACTIVITY,
                    topic=f"{bundle_id}.push-type.liveactivity",
                    payload=la_payload,
                )
                log.info(
                    "push.la_sent",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    token=_mask_token(tok.token),
                    environment=tok.environment.value,
                )
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "push.la_failed",
                    owner_id=str(owner_id),
                    mochi_item_id=str(mochi_item_id),
                    token=_mask_token(tok.token),
                    environment=tok.environment.value,
                    exception=str(exc),
                    exc_info=True,
                )

    @staticmethod
    def _build_alert(mochi_item_id: UUID, n: AnalysisNotification) -> dict[str, object]:
        if n.needs_review:
            title = "어떤 의도로 남겼나요?"
            body = n.summary or "탭해서 확인해주세요"
        else:
            title = "이렇게 저장했어요"
            body = n.summary or "분석을 완료했어요"
        return {
            "aps": {
                "alert": {"title": title, "body": body[:_ALERT_BODY_MAX]},
                "sound": "default",
            },
            "mochiItemID": str(mochi_item_id),
        }

    @staticmethod
    def _build_live_activity(n: AnalysisNotification) -> dict[str, object]:
        # label 은 non-null 보장 — iOS `MochiLiveActivityAttributes.Candidate.label` 이 비옵셔널이라
        # null 이면 시스템 content-state 자동 decode 가 throw → background LA 갱신이 무음 드롭된다.
        # (ReviewOption.label 은 str|None. reasoning 은 항상 str 이라 그대로.)
        candidates = [
            {
                "intentType": r.intent_type.value,
                "label": r.label or r.intent_type.value,
                "reasoning": r.reasoning,
            }
            for r in n.review_options[:3]
        ]
        content_state: dict[str, object] = {
            "phase": "ready",
            "needsReview": n.needs_review,
            "summary": (n.summary or "")[:120],
            "candidates": candidates,
        }
        payload: dict[str, object] = {
            "aps": {
                "timestamp": int(time.time()),
                "event": "update",
                "content-state": content_state,
            }
        }
        # 4KB 가드 — 초과 시 후보를 줄여 맞춘다(reasoning 비움 → 후보 수 축소). best-effort, assert 금지.
        while len(json.dumps(payload, ensure_ascii=False).encode()) > _LA_PAYLOAD_MAX_BYTES and candidates:
            if any(c["reasoning"] for c in candidates):
                for c in candidates:
                    c["reasoning"] = ""
            else:
                candidates.pop()
            content_state["candidates"] = candidates
        return payload


def _mask_token(token: str) -> str:
    if len(token) <= 14:
        return f"{token[:4]}...{token[-4:]}"
    return f"{token[:8]}...{token[-6:]}"
