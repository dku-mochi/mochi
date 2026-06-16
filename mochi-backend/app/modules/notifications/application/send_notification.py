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
from app.modules.notifications.application.send_recall_notification import _is_invalid_token
from app.modules.notifications.domain.entities import APNsPushType, PushTokenType
from app.modules.notifications.domain.ports import APNsClient, PushTokenRepository
from app.modules.notifications.infrastructure.apns_client import APNsError

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

    async def run(self, *, owner_id: UUID, mochi_item_id: UUID, notification: AnalysisNotification) -> None:
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
            except APNsError as exc:
                # 410/Unregistered/BadDeviceToken → 죽은 토큰 무효화(삭제). 안 그러면 앱 재설치로
                # 죽은 토큰이 영영 쌓여 매번 재발송된다(회수 경로와 동일 정책, codex-5).
                if _is_invalid_token(exc):
                    await self._tokens.delete(token=tok.token)
                    log.info(
                        "push.token_invalidated",
                        owner_id=str(owner_id),
                        token=_mask_token(tok.token),
                        environment=tok.environment.value,
                        reason=exc.reason or str(exc.status_code),
                    )
                else:
                    log.warning(
                        "push.alert_failed",
                        owner_id=str(owner_id),
                        mochi_item_id=str(mochi_item_id),
                        token=_mask_token(tok.token),
                        environment=tok.environment.value,
                        exception=str(exc),
                        exc_info=True,
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

        # 2) Live Activity push-to-start — needs_review=true 일 때만. owner 의 push-to-start 토큰으로
        # LA 를 background(잠금)에서 시작(start push). 진행중/완료 LA 는 더 이상 띄우지 않는다(팀 결정
        # 2026-06-09): needs_review 가 아닌 분석완료는 위 alert push 로 충분하다. iOS 17.2+ 단말만 토큰
        # 을 등록하므로 미등록·17.2 미만·LA 비활성 단말은 alert push 가 fallback 으로 메운다.
        if notification.needs_review:
            la_payload = self._build_la_start(mochi_item_id, notification)
            la_start_tokens = await self._tokens.list_for_owner(
                owner_id=owner_id, token_type=PushTokenType.LA_START
            )
            log.info(
                "push.la_start_targets",
                owner_id=str(owner_id),
                mochi_item_id=str(mochi_item_id),
                count=len(la_start_tokens),
            )
            for tok in la_start_tokens:
                try:
                    await self._apns.send(
                        token=tok.token,
                        environment=tok.environment,
                        push_type=APNsPushType.LIVEACTIVITY,
                        topic=f"{bundle_id}.push-type.liveactivity",
                        payload=la_payload,
                    )
                    log.info(
                        "push.la_start_sent",
                        owner_id=str(owner_id),
                        mochi_item_id=str(mochi_item_id),
                        token=_mask_token(tok.token),
                        environment=tok.environment.value,
                    )
                except APNsError as exc:
                    # 410/Unregistered → 죽은 LA push-to-start 토큰 무효화(삭제). 앱 재설치 시 옛 토큰이
                    # 무효화되지 않아 매번 410 재발송되던 문제 해결(alert 경로와 동일 정책).
                    if _is_invalid_token(exc):
                        await self._tokens.delete(token=tok.token)
                        log.info(
                            "push.token_invalidated",
                            owner_id=str(owner_id),
                            token=_mask_token(tok.token),
                            environment=tok.environment.value,
                            reason=exc.reason or str(exc.status_code),
                        )
                    else:
                        log.warning(
                            "push.la_start_failed",
                            owner_id=str(owner_id),
                            mochi_item_id=str(mochi_item_id),
                            token=_mask_token(tok.token),
                            environment=tok.environment.value,
                            exception=str(exc),
                            exc_info=True,
                        )
                except Exception as exc:  # noqa: BLE001
                    log.warning(
                        "push.la_start_failed",
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
    def _build_la_start(mochi_item_id: UUID, n: AnalysisNotification) -> dict[str, object]:
        # push-to-start: 백엔드가 LA 를 background(잠금)에서 **시작**한다(`event: start`). 이미 떠 있는
        # LA 를 갱신하는 update 와 달리 `attributes-type` + `attributes`(불변 초기값)를 함께 싣는다.
        # `attributes` 키는 iOS `MochiLiveActivityAttributes` 저장 프로퍼티와 **정확 일치**해야 한다
        # (mochiItemID/captureCaption/thumbnailRelativePath). 썸네일 로컬경로(App Group 상대경로)는
        # 백엔드가 모르므로 null — Widget 이 placeholder 로 렌더한다.
        #
        # label 은 non-null 보장 — iOS `Candidate.label` 이 비옵셔널이라 null 이면 시스템 자동 decode 가
        # throw → start 가 무음 드롭된다. (ReviewOption.label 은 str|None. reasoning 은 항상 str.)
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
            "needsReview": True,
            "summary": (n.summary or "")[:120],
            "candidates": candidates,
        }
        attributes: dict[str, object] = {
            "mochiItemID": str(mochi_item_id),
            "captureCaption": (n.summary or "새 기록")[:40],
            "thumbnailRelativePath": None,
        }
        payload: dict[str, object] = {
            "aps": {
                "timestamp": int(time.time()),
                "event": "start",
                "attributes-type": "MochiLiveActivityAttributes",
                "attributes": attributes,
                "content-state": content_state,
            }
        }
        # 4KB 가드 — start payload 는 attributes 까지 포함해 update 보다 크다. 초과 시 reasoning 비움 →
        # 후보 수 축소. best-effort, assert 금지.
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
