"""능동 회수 알림 — 하드 가드 (순수함수, DB 무관).

정본 `journal/proactive-recall/notification-agent.md` §4 / `schema.md` §4(불변식).
워커(P3)가 DB 에서 읽은 사실(직전 dismiss 시각·하루 발송 카운트·트랙B 존재)을 값으로 넘기면
"보낸다 / deferred / skipped" 판정만 한다. per-owner 직렬화(advisory lock)는 워커가 건다 —
이 모듈은 카운트 자체는 안 한다(이미 센 결과를 받는다).

KST local date 기준 cap·야간 판정(codex-1). quiet 윈도우는 [start, end) 시각(KST hour).
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from app.modules.notifications.application.recall_occurrence import KST

# 가드 결과 — outbox status/skip_reason 매핑.
GUARD_ALLOW = "allow"  # materialize 진행
GUARD_DEFER = "defer"  # status='deferred' + next_retry_at (재배치 가능, codex-4)
GUARD_SKIP = "skip"  # status='skipped' (terminal)


@dataclass(frozen=True, slots=True)
class GuardDecision:
    """가드 판정. action=allow 면 fire_at(가드가 shift 했을 수 있음)을, defer 면 next_retry_at 을 준다."""

    action: str  # GUARD_ALLOW | GUARD_DEFER | GUARD_SKIP
    skip_reason: str | None = None
    fire_at: datetime | None = None  # allow 시 (shift 됐을 수 있는) 발송시각
    next_retry_at: datetime | None = None  # defer 시 재평가 시각


def _to_kst_date(value: datetime) -> date:
    return value.astimezone(KST).date()


def check_dismiss_cooldown(
    *,
    last_dismissed_at: datetime | None,
    now: datetime,
    cooldown_days: int,
) -> GuardDecision | None:
    """dismiss cooldown(§4 #4, plan 경계 넘음). source_intent_id 기준 직전 dismiss 가 쿨다운 내면 skip.

    None = 통과(쿨다운 아님). 호출부가 source_intent 의 outbox 에서 MAX(dismissed_at) 을 넘긴다.
    """
    if last_dismissed_at is None:
        return None
    if now - last_dismissed_at.astimezone(now.tzinfo or KST) < timedelta(days=cooldown_days):
        return GuardDecision(action=GUARD_SKIP, skip_reason="dismissed_cooldown")
    return None


def check_track_b_yield(
    *,
    kind: str,
    has_deadline_push_same_day: bool,
    fire_at: datetime,
) -> GuardDecision | None:
    """트랙B 양보(§4): 같은 KST day 에 owner 의 deadline push 가 이미 있으면 회수(spaced/recall)는 양보.

    deadline/nudge 는 양보 안 한다(마감·실행 알림은 회수보다 우선). None = 통과.
    next_retry_at = 다음날 KST 0시(cap 과 동일 — yielded_to_b deferred 가 next_retry_at=NULL 이면
    워커 _reactivate_deferred 가 영원히 SELECT 못 해 영구 소실, codex P1#1).
    """
    if kind in ("deadline", "nudge"):
        return None
    if has_deadline_push_same_day:
        fire_kst_date = _to_kst_date(fire_at)
        next_day_kst = datetime.combine(fire_kst_date + timedelta(days=1), time(0, 0), tzinfo=KST)
        return GuardDecision(
            action=GUARD_DEFER,
            skip_reason="yielded_to_b",
            next_retry_at=next_day_kst.astimezone(fire_at.tzinfo),
        )
    return None


def check_quiet_hours(
    *,
    fire_at: datetime,
    quiet_start_hour: int,
    quiet_end_hour: int,
) -> GuardDecision:
    """야간 무음(§4): fire_at 이 KST quiet 윈도우(예 21~8시) 안이면 윈도우 종료로 shift 후 allow.

    윈도우가 자정을 넘으므로(start>end) "start 이상 또는 end 미만"이 quiet. 통과면 원래 fire_at allow.
    shift 는 quiet 종료(quiet_end_hour:00 KST) — 윈도우 밖이 되어 더 이상 야간 가드에 안 걸린다.
    """
    fire_kst = fire_at.astimezone(KST)
    hour = fire_kst.hour
    in_quiet = (hour >= quiet_start_hour) or (hour < quiet_end_hour)
    if not in_quiet:
        return GuardDecision(action=GUARD_ALLOW, fire_at=fire_at)
    # quiet 종료시각으로 민다: 같은 날(hour<end)이면 그날 end, 밤(hour>=start)이면 다음날 end.
    base_date = fire_kst.date()
    if hour >= quiet_start_hour:
        base_date = base_date + timedelta(days=1)
    shifted_kst = datetime.combine(base_date, time(quiet_end_hour, 0), tzinfo=KST)
    return GuardDecision(action=GUARD_DEFER, skip_reason="night", next_retry_at=shifted_kst.astimezone(fire_at.tzinfo))


def check_daily_cap(
    *,
    fire_at: datetime,
    same_day_count: int,
    daily_cap: int,
) -> GuardDecision | None:
    """하루 cap(§4): owner 의 fire_at KST local date pending/sent 카운트가 cap 이상이면 deferred.

    next_retry_at = 다음날 KST 0시(D-1 마감이 cap 에 영구 소실 안 되게, codex-4 — expires 전까지 재배치).
    None = 통과(cap 미만). same_day_count 는 호출부가 KST date 기준으로 세서 넘긴다.
    """
    if same_day_count < daily_cap:
        return None
    fire_kst_date = _to_kst_date(fire_at)
    next_day_kst = datetime.combine(fire_kst_date + timedelta(days=1), time(0, 0), tzinfo=KST)
    return GuardDecision(
        action=GUARD_DEFER,
        skip_reason="cap",
        next_retry_at=next_day_kst.astimezone(fire_at.tzinfo),
    )
