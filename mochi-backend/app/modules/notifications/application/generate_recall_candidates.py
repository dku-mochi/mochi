"""능동 회수 트랙 C 후보 생성 + 발송 게이트 (P7~P9) 유스케이스.

정본 `journal/proactive-recall/tech-plan.md` §8 / `notification-agent.md` §3(보낸다/참는다).

분석 done 후 worker 가 best-effort 로 호출(P2 플래너 형제). 새 item(B)의 임베딩 ANN 으로 유사한
과거 기록(A)을 찾아, 게이트(애매하면 안 보낸다)를 통과하면 `notification_outbox` 에 직행 적재
(kind=recall, plan_id NULL) → 기존 발송·반응·landing 파이프라인이 처리한다.

게이트(P8): 점수 임계(repo 가 이미 적용)·재스팸 dedup·dismiss cooldown → skip(미적재).
야간/cap/트랙B 양보는 fire_at 을 미래로 민다(drop 아님) — 트랙 C 는 plan 이 없어
worker 의 deferred 회생을 못 타므로, defer 대신 pending 의 future fire_at 으로 표현한다.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from app.core.logging import get_logger
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleKind, IntentInstance
from app.modules.notifications.application.recall_guards import (
    GUARD_ALLOW,
    check_daily_cap,
    check_dismiss_cooldown,
    check_quiet_hours,
    check_track_b_yield,
)
from app.modules.notifications.application.recall_occurrence import KST
from app.modules.notifications.domain.recall_candidate import RecallCandidateRepositoryPort

log = get_logger("notifications.recall_candidate")

_RECALL_KIND = "recall"


class GenerateRecallCandidates:
    """새 item → ANN 후보 → 게이트 → notification_outbox 직행(kind=recall)."""

    def __init__(
        self,
        *,
        candidates: RecallCandidateRepositoryPort,
        mochi_items: MochiItemRepository,
        min_score: float,
        candidate_limit: int,
        dedup_cooldown_days: int,
        dismiss_cooldown_days: int,
        daily_cap: int,
        quiet_start_hour: int,
        quiet_end_hour: int,
        expires_days: int,
    ) -> None:
        self._candidates = candidates
        self._items = mochi_items
        self._min_score = min_score
        self._candidate_limit = candidate_limit
        self._dedup_cooldown_days = dedup_cooldown_days
        self._dismiss_cooldown_days = dismiss_cooldown_days
        self._daily_cap = daily_cap
        self._quiet_start_hour = quiet_start_hour
        self._quiet_end_hour = quiet_end_hour
        self._expires_days = expires_days

    async def run(self, *, owner_id: UUID, mochi_item_id: UUID) -> bool:
        """B(새 item)에서 회수 1건을 생성. 적재했으면 True, 게이트로 보류했으면 False."""
        now = datetime.now(UTC)
        source = await self._items.find_by_id(owner_id=owner_id, mochi_item_id=mochi_item_id)
        if source is None:
            return False

        found = await self._candidates.find_similar(
            owner_id=owner_id, source_item_id=mochi_item_id,
            min_score=self._min_score, limit=self._candidate_limit,
        )
        if not found:
            return False
        best = found[0]  # score desc — 가장 가까운 과거 기록(A)이 회수 앵커

        anchor = await self._items.find_by_id(owner_id=owner_id, mochi_item_id=best.item_id)
        if anchor is None:
            return False  # ANN 직후 삭제
        # generic copy 금지(§3): 근거 명사(제목/요약)가 있어야 발송.
        if not (anchor.display_title or best.summary):
            return self._skip(owner_id, best.item_id, "generic_copy")

        intent = _representative_intent(anchor)
        source_intent_id = intent.id if intent is not None else None

        # 재스팸 dedup — 같은 item 을 최근 회수했으면 보류.
        if await self._candidates.recent_recall_exists(
            owner_id=owner_id, source_item_id=best.item_id,
            since=now - timedelta(days=self._dedup_cooldown_days),
        ):
            return self._skip(owner_id, best.item_id, "recent_recall")

        # dismiss cooldown(plan 경계 넘음, source_intent 기준).
        last_dismissed = await self._candidates.last_dismissed_for_intent(
            owner_id=owner_id, source_intent_id=source_intent_id
        )
        if check_dismiss_cooldown(
            last_dismissed_at=last_dismissed, now=now, cooldown_days=self._dismiss_cooldown_days
        ) is not None:
            return self._skip(owner_id, best.item_id, "dismissed_cooldown")

        fire_at = await self._gate_fire_at(owner_id=owner_id, now=now)
        title, body = _render_content(anchor=anchor, source=source, anchor_summary=best.summary)
        collapse = (str(source_intent_id) if source_intent_id else str(best.item_id))[:64]
        event_id = await self._candidates.insert_recall(
            owner_id=owner_id,
            source_item_id=best.item_id,
            source_intent_id=source_intent_id,
            fire_at=fire_at,
            expires_at=now + timedelta(days=self._expires_days),
            title=title,
            body=body,
            collapse_id=collapse,
        )
        log.info(
            "recall.candidate_created",
            owner_id=str(owner_id),
            source_item_id=str(best.item_id),
            trigger_item_id=str(mochi_item_id),
            score=round(best.score, 3),
            fire_at=fire_at.isoformat(),
            event_id=str(event_id),
        )
        return True

    async def _gate_fire_at(self, *, owner_id: UUID, now: datetime) -> datetime:
        """야간/cap/트랙B 를 fire_at 미루기로 표현(트랙 C 는 plan 없어 deferred 회생 불가).

        순서: 트랙B 양보 → cap → 야간(마지막). 야간을 마지막에 둬 최종 fire_at 이 quiet 밖(아침)이 되게.
        """
        fire_at = now
        # 트랙B 양보 — 같은 KST day deadline push 있으면 다음날로.
        if await self._candidates.has_deadline_push_same_day(
            owner_id=owner_id, kst_date=fire_at.astimezone(KST).date()
        ):
            yielded = check_track_b_yield(
                kind=_RECALL_KIND, has_deadline_push_same_day=True, fire_at=fire_at
            )
            if yielded is not None and yielded.next_retry_at is not None:
                fire_at = yielded.next_retry_at
        # 하루 cap — 초과면 다음날로.
        cnt = await self._candidates.same_day_count(
            owner_id=owner_id, kst_date=fire_at.astimezone(KST).date()
        )
        capped = check_daily_cap(fire_at=fire_at, same_day_count=cnt, daily_cap=self._daily_cap)
        if capped is not None and capped.next_retry_at is not None:
            fire_at = capped.next_retry_at
        # 야간 무음 — quiet 안이면 종료(아침)로.
        quiet = check_quiet_hours(
            fire_at=fire_at,
            quiet_start_hour=self._quiet_start_hour,
            quiet_end_hour=self._quiet_end_hour,
        )
        if quiet.action == GUARD_ALLOW:
            return quiet.fire_at or fire_at
        return quiet.next_retry_at or fire_at

    def _skip(self, owner_id: UUID, item_id: UUID, reason: str) -> bool:
        log.info(
            "recall.candidate_skipped",
            owner_id=str(owner_id), source_item_id=str(item_id), reason=reason,
        )
        return False


def _representative_intent(item: MochiItem) -> IntentInstance | None:
    """A 의 대표 intent(첫 non-archived) — 딥링크·cooldown 키. 없으면 None."""
    return next(
        (i for i in item.intent_instances if i.lifecycle.kind is not InstanceLifecycleKind.ARCHIVED),
        None,
    )


def _render_content(
    *, anchor: MochiItem, source: MochiItem, anchor_summary: str | None
) -> tuple[str, str]:
    """결정적 본문 — 근거 명사(제목/요약)로 비단정 톤(notification-agent.md §3). LLM copy 아님."""
    anchor_name = anchor.display_title or _first_sentence(anchor_summary) or "다시 보면 좋을 기억"
    source_name = source.display_title or _first_sentence(source.summary)
    if source_name and source_name != anchor_name:
        body = f"방금 저장한 '{source_name}', 지난번 '{anchor_name}'과 이어져요. 다시 볼까요?"
    else:
        body = f"지난번 '{anchor_name}', 다시 볼까요?"
    return anchor_name, body


def _first_sentence(summary: str | None) -> str:
    if not summary or not summary.strip():
        return ""
    head = summary.strip().splitlines()[0].strip()
    return head[:60]
