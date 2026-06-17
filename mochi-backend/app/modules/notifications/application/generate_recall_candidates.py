"""능동 회수 트랙 C — 후보 생성 + LLM 선별 게이트 (P7~P9, 2026-06-17 LLM 게이트 전환).

정본 `journal/proactive-recall/track-c-llm-gate-decision.md` / `notification-agent.md` §3.

분석 done 후 worker 가 best-effort 로 호출. 흐름:
  새 item(B) → ANN overfetch → 얇은 필터(근중복·archived) → LLM 선별 게이트(0~1건 채택 + 한국어 작문)
  → 결정적 백스톱(owner 쿨다운·dedup·dismiss·cap·야간·트랙B) → notification_outbox(kind=recall) 직행.

코사인은 판별자가 아니라 후보 추림용 바닥값(min_score)일 뿐 — 선별·메시지는 LLM 이 한다(같은 결정
재등장 vs 단순 토픽 유사 구분). cap/dedup/쿨다운은 LLM 비결정성·worker 동시성 레이스 방어로 결정적
규칙 유지(per-owner advisory lock 하 직렬). gate_enabled=False 면 결정적 best-1 폴백(롤백 안전판),
gate_dry_run=True 면 결정 로그만 남기고 적재 안 함(발송 0 튜닝).
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
    check_quiet_hours,
    check_track_b_yield,
)
from app.modules.notifications.application.recall_guards import (
    check_dismiss_cooldown as _check_dismiss,
)
from app.modules.notifications.application.recall_occurrence import KST
from app.modules.notifications.domain.recall_candidate import RecallCandidateRepositoryPort
from app.modules.notifications.domain.recall_gate import (
    RecallGateCandidate,
    RecallGateInput,
    RecallGatePort,
)

log = get_logger("notifications.recall_candidate")

_RECALL_KIND = "recall"


class GenerateRecallCandidates:
    """새 item → ANN overfetch → 필터 → LLM 게이트 → 결정적 백스톱 → outbox 직행(kind=recall)."""

    def __init__(
        self,
        *,
        candidates: RecallCandidateRepositoryPort,
        mochi_items: MochiItemRepository,
        gate: RecallGatePort,
        min_score: float,
        overfetch_limit: int,
        gate_topn: int,
        near_dup_score: float,
        gate_enabled: bool,
        gate_dry_run: bool,
        dedup_cooldown_days: int,
        dismiss_cooldown_days: int,
        owner_cooldown_hours: int,
        daily_cap: int,
        quiet_start_hour: int,
        quiet_end_hour: int,
        expires_days: int,
    ) -> None:
        self._candidates = candidates
        self._items = mochi_items
        self._gate = gate
        self._min_score = min_score
        self._overfetch_limit = overfetch_limit
        self._gate_topn = gate_topn
        self._near_dup_score = near_dup_score
        self._gate_enabled = gate_enabled
        self._gate_dry_run = gate_dry_run
        self._dedup_cooldown_days = dedup_cooldown_days
        self._dismiss_cooldown_days = dismiss_cooldown_days
        self._owner_cooldown_hours = owner_cooldown_hours
        self._daily_cap = daily_cap
        self._quiet_start_hour = quiet_start_hour
        self._quiet_end_hour = quiet_end_hour
        self._expires_days = expires_days

    async def run(self, *, owner_id: UUID, mochi_item_id: UUID) -> bool:
        """B(새 item)에서 회수 1건 생성. 적재했으면 True, 게이트/백스톱으로 보류면 False."""
        now = datetime.now(UTC)
        # 동시 저장(worker concurrency) 직렬화 — cap/쿨다운 카운트 레이스 방지(발송 워커와 동일 lock).
        await self._candidates.acquire_owner_lock(owner_id=owner_id)

        source = await self._items.find_by_id(owner_id=owner_id, mochi_item_id=mochi_item_id)
        if source is None:
            return False

        # owner 쿨다운(트리거 디바운스) — 최근 회수 적재가 있으면 보류(난사·버스트 차단).
        if self._owner_cooldown_hours > 0 and await self._candidates.recent_owner_recall_exists(
            owner_id=owner_id, since=now - timedelta(hours=self._owner_cooldown_hours)
        ):
            return self._skip(owner_id, mochi_item_id, "owner_cooldown")

        gate_cands, anchors = await self._build_candidates(owner_id=owner_id, source=source)
        if not gate_cands:
            return False

        chosen, body = await self._select(source=source, gate_cands=gate_cands, anchors=anchors)
        if chosen is None:
            return self._skip(owner_id, mochi_item_id, "gate_reject")
        anchor = anchors[chosen.item_id]
        intent = _representative_intent(anchor)
        source_intent_id = intent.id if intent is not None else None

        # 결정적 백스톱 — LLM 결과와 무관하게 재스팸·dismiss 방어.
        if await self._candidates.recent_recall_exists(
            owner_id=owner_id, source_item_id=chosen.item_id,
            since=now - timedelta(days=self._dedup_cooldown_days),
        ):
            return self._skip(owner_id, chosen.item_id, "recent_recall")
        last_dismissed = await self._candidates.last_dismissed_for_intent(
            owner_id=owner_id, source_intent_id=source_intent_id
        )
        if _check_dismiss(
            last_dismissed_at=last_dismissed, now=now, cooldown_days=self._dismiss_cooldown_days
        ) is not None:
            return self._skip(owner_id, chosen.item_id, "dismissed_cooldown")

        if self._gate_dry_run:
            log.info(
                "recall.gate_dry_run", owner_id=str(owner_id),
                source_item_id=str(chosen.item_id), trigger_item_id=str(mochi_item_id),
                score=round(chosen.score, 3), body=body[:120],
            )
            return False

        fire_at = await self._gate_fire_at(owner_id=owner_id, now=now)
        title = anchor.display_title or _first_sentence(chosen.summary) or "다시 보면 좋을 기억"
        collapse = (str(source_intent_id) if source_intent_id else str(chosen.item_id))[:64]
        event_id = await self._candidates.insert_recall(
            owner_id=owner_id, source_item_id=chosen.item_id, source_intent_id=source_intent_id,
            fire_at=fire_at, expires_at=now + timedelta(days=self._expires_days),
            title=title, body=body, collapse_id=collapse,
        )
        log.info(
            "recall.candidate_created", owner_id=str(owner_id),
            source_item_id=str(chosen.item_id), trigger_item_id=str(mochi_item_id),
            score=round(chosen.score, 3), fire_at=fire_at.isoformat(), event_id=str(event_id),
        )
        return True

    async def _build_candidates(
        self, *, owner_id: UUID, source: MochiItem
    ) -> tuple[list[RecallGateCandidate], dict[UUID, MochiItem]]:
        """ANN overfetch → 근중복·archived 제외 → 앵커 로드 → 게이트 후보(topn) + 앵커맵."""
        found = await self._candidates.find_similar(
            owner_id=owner_id, source_item_id=source.id,
            min_score=self._min_score, limit=self._overfetch_limit,
        )
        anchors: dict[UUID, MochiItem] = {}
        gate_cands: list[RecallGateCandidate] = []
        for cand in found:
            if len(gate_cands) >= self._gate_topn:
                break
            if cand.score >= self._near_dup_score:
                continue  # 근중복(재저장) 제외 — 앵커 로드 전에 컷(비용)
            anchor = await self._items.find_by_id(owner_id=owner_id, mochi_item_id=cand.item_id)
            if anchor is None:
                continue
            live_types = _live_intent_types(anchor)
            title = anchor.display_title or _first_sentence(cand.summary)
            if not (live_types or title):
                continue  # 전부 archived + 제목 없음 = 회수 가치 없음
            gap_days = max(0.0, (source.created_at - anchor.created_at).total_seconds() / 86400)
            anchors[cand.item_id] = anchor
            gate_cands.append(RecallGateCandidate(
                index=len(gate_cands), item_id=cand.item_id, title=title or "(제목없음)",
                summary=cand.summary, intent_types=live_types, gap_days=gap_days, score=cand.score,
            ))
        return gate_cands, anchors

    async def _select(
        self, *, source: MochiItem, gate_cands: list[RecallGateCandidate],
        anchors: dict[UUID, MochiItem],
    ) -> tuple[RecallGateCandidate | None, str]:
        """LLM 게이트로 0~1건 선별 + 한국어 본문. gate_enabled=False 면 결정적 best-1 폴백(롤백 안전판)."""
        if not self._gate_enabled:
            best = gate_cands[0]  # score desc 첫째
            anchor_name = anchors[best.item_id].display_title or _first_sentence(best.summary)
            if not anchor_name:
                return None, ""
            return best, _render_fallback(anchor_name=anchor_name, source=source)
        try:
            decision = await self._gate.decide(gate_input=RecallGateInput(
                trigger_title=source.display_title or _first_sentence(source.summary) or "방금 저장한 기록",
                trigger_summary=source.summary,
                trigger_types=_live_intent_types(source),
                candidates=tuple(gate_cands),
            ))
        except Exception as exc:  # noqa: BLE001
            log.warning("recall.gate_failed", source_item_id=str(source.id), exception=str(exc), exc_info=True)
            return None, ""
        if not decision.recall or decision.chosen_index is None:
            return None, ""
        if not (0 <= decision.chosen_index < len(gate_cands)) or not decision.message.strip():
            return None, ""
        return gate_cands[decision.chosen_index], decision.message.strip()

    async def _gate_fire_at(self, *, owner_id: UUID, now: datetime) -> datetime:
        """야간/cap/트랙B 를 fire_at 미루기로 표현(트랙 C 는 plan 없어 deferred 회생 불가).

        순서: 트랙B 양보 → cap → 야간(마지막). 야간을 마지막에 둬 최종 fire_at 이 quiet 밖(아침)이 되게.
        """
        fire_at = now
        if await self._candidates.has_deadline_push_same_day(
            owner_id=owner_id, kst_date=fire_at.astimezone(KST).date()
        ):
            yielded = check_track_b_yield(
                kind=_RECALL_KIND, has_deadline_push_same_day=True, fire_at=fire_at
            )
            if yielded is not None and yielded.next_retry_at is not None:
                fire_at = yielded.next_retry_at
        cnt = await self._candidates.same_day_count(
            owner_id=owner_id, kst_date=fire_at.astimezone(KST).date()
        )
        capped = check_daily_cap(fire_at=fire_at, same_day_count=cnt, daily_cap=self._daily_cap)
        if capped is not None and capped.next_retry_at is not None:
            fire_at = capped.next_retry_at
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


def _live_intent_types(item: MochiItem) -> tuple[str, ...]:
    """non-archived intent 타입 집합(정렬). 전부 archived 면 빈 튜플."""
    return tuple(sorted({
        i.intent_type.value for i in item.intent_instances
        if i.lifecycle.kind is not InstanceLifecycleKind.ARCHIVED
    }))


def _representative_intent(item: MochiItem) -> IntentInstance | None:
    """A 의 대표 intent(첫 non-archived) — 딥링크·cooldown 키. 없으면 None."""
    return next(
        (i for i in item.intent_instances if i.lifecycle.kind is not InstanceLifecycleKind.ARCHIVED),
        None,
    )


def _render_fallback(*, anchor_name: str, source: MochiItem) -> str:
    """gate_enabled=False 폴백용 결정적 본문(비단정 톤). LLM 경로면 안 쓰임."""
    source_name = source.display_title or _first_sentence(source.summary)
    if source_name and source_name != anchor_name:
        return f"방금 저장한 '{source_name}', 지난번 '{anchor_name}'과 이어져요. 다시 볼까요?"
    return f"지난번 '{anchor_name}', 다시 볼까요?"


def _first_sentence(summary: str | None) -> str:
    if not summary or not summary.strip():
        return ""
    head = summary.strip().splitlines()[0].strip()
    return head[:60]
