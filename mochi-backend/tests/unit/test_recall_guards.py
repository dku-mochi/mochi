"""능동 회수 알림 — 하드 가드 순수 단위테스트 (P3, DB 무관).

cap defer / night defer / dismiss cooldown skip / 트랙B yield (시간·사실 주입).
종료연동(archived→cancelled)은 워커 DB 로직이라 여기 대상 아님(send/integration). 정본 §4.
"""

from datetime import UTC, datetime, timedelta

from app.modules.notifications.application.recall_guards import (
    GUARD_ALLOW,
    GUARD_DEFER,
    GUARD_SKIP,
    check_daily_cap,
    check_dismiss_cooldown,
    check_quiet_hours,
    check_track_b_yield,
)
from app.modules.notifications.application.recall_occurrence import KST

# ---------- dismiss cooldown ----------


def test_dismiss_cooldown_skips_within_window():
    now = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)
    last = now - timedelta(days=3)  # 7일 쿨다운 내
    out = check_dismiss_cooldown(last_dismissed_at=last, now=now, cooldown_days=7)
    assert out is not None
    assert out.action == GUARD_SKIP
    assert out.skip_reason == "dismissed_cooldown"


def test_dismiss_cooldown_passes_after_window():
    now = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)
    last = now - timedelta(days=10)
    assert check_dismiss_cooldown(last_dismissed_at=last, now=now, cooldown_days=7) is None


def test_dismiss_cooldown_none_when_never_dismissed():
    now = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)
    assert check_dismiss_cooldown(last_dismissed_at=None, now=now, cooldown_days=7) is None


# ---------- track B yield ----------

_FIRE = datetime(2026, 6, 16, 5, 0, tzinfo=UTC)  # 14:00 KST 2026-06-16


def test_track_b_yield_defers_spaced_when_deadline_same_day():
    out = check_track_b_yield(kind="spaced", has_deadline_push_same_day=True, fire_at=_FIRE)
    assert out is not None
    assert out.action == GUARD_DEFER
    assert out.skip_reason == "yielded_to_b"
    # P1#1 회귀: next_retry_at 가 있어야 워커 _reactivate_deferred 가 회생시킨다(영구 소실 방지).
    assert out.next_retry_at is not None
    retry_kst = out.next_retry_at.astimezone(KST)
    assert retry_kst.hour == 0
    assert retry_kst.date().isoformat() == "2026-06-17"  # 다음날 KST 0시(cap 과 동일)


def test_track_b_recall_yields_too():
    out = check_track_b_yield(kind="recall", has_deadline_push_same_day=True, fire_at=_FIRE)
    assert out is not None and out.action == GUARD_DEFER
    assert out.next_retry_at is not None


def test_track_b_deadline_does_not_yield():
    assert (
        check_track_b_yield(kind="deadline", has_deadline_push_same_day=True, fire_at=_FIRE) is None
    )


def test_track_b_nudge_does_not_yield():
    assert check_track_b_yield(kind="nudge", has_deadline_push_same_day=True, fire_at=_FIRE) is None


def test_track_b_no_deadline_passes():
    assert (
        check_track_b_yield(kind="spaced", has_deadline_push_same_day=False, fire_at=_FIRE) is None
    )


# ---------- quiet hours ----------


def test_quiet_hours_allows_daytime():
    # 14:00 KST = 05:00 UTC → 윈도우 밖.
    fire = datetime(2026, 6, 16, 5, 0, tzinfo=UTC)
    out = check_quiet_hours(fire_at=fire, quiet_start_hour=21, quiet_end_hour=8)
    assert out.action == GUARD_ALLOW
    assert out.fire_at == fire


def test_quiet_hours_defers_late_night_to_next_morning():
    # 23:00 KST = 14:00 UTC → quiet(>=21). shift → 다음날 08:00 KST.
    fire = datetime(2026, 6, 16, 14, 0, tzinfo=UTC)
    out = check_quiet_hours(fire_at=fire, quiet_start_hour=21, quiet_end_hour=8)
    assert out.action == GUARD_DEFER
    assert out.skip_reason == "night"
    assert out.next_retry_at is not None
    shifted = out.next_retry_at.astimezone(KST)
    assert shifted.hour == 8
    assert shifted.date().isoformat() == "2026-06-17"  # 밤 → 다음날


def test_quiet_hours_defers_early_morning_same_day():
    # 06:00 KST = 21:00 UTC(전날) → quiet(<8). shift → 같은 KST day 08:00.
    fire = datetime(2026, 6, 15, 21, 0, tzinfo=UTC)  # 2026-06-16 06:00 KST
    out = check_quiet_hours(fire_at=fire, quiet_start_hour=21, quiet_end_hour=8)
    assert out.action == GUARD_DEFER
    shifted = out.next_retry_at.astimezone(KST)
    assert shifted.hour == 8
    assert shifted.date().isoformat() == "2026-06-16"  # 새벽 → 같은 날 아침


# ---------- daily cap ----------


def test_daily_cap_passes_under_limit():
    fire = datetime(2026, 6, 16, 5, 0, tzinfo=UTC)
    assert check_daily_cap(fire_at=fire, same_day_count=2, daily_cap=3) is None


def test_daily_cap_defers_at_limit_to_next_kst_day():
    fire = datetime(2026, 6, 16, 5, 0, tzinfo=UTC)  # 14:00 KST 2026-06-16
    out = check_daily_cap(fire_at=fire, same_day_count=3, daily_cap=3)
    assert out is not None
    assert out.action == GUARD_DEFER
    assert out.skip_reason == "cap"
    # next_retry = 다음날 KST 0시(D-1 마감이 cap 에 영구 소실 안 되게).
    retry_kst = out.next_retry_at.astimezone(KST)
    assert retry_kst.hour == 0
    assert retry_kst.date().isoformat() == "2026-06-17"
