"""능동 회수 알림 — 하드 가드 순수 단위테스트 (P3, DB 무관).

cap defer / night defer / dismiss cooldown skip / 트랙B yield (시간·사실 주입).
종료연동(archived→cancelled)은 워커 DB 로직이라 여기 대상 아님(send/integration). 정본 §4.
"""

from datetime import UTC, datetime, timedelta

from app.modules.notifications.application.recall_guards import (
    GUARD_DEFER,
    GUARD_SKIP,
    check_dismiss_cooldown,
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
    assert check_track_b_yield(kind="deadline", has_deadline_push_same_day=True, fire_at=_FIRE) is None


def test_track_b_nudge_does_not_yield():
    assert check_track_b_yield(kind="nudge", has_deadline_push_same_day=True, fire_at=_FIRE) is None


def test_track_b_no_deadline_passes():
    assert check_track_b_yield(kind="spaced", has_deadline_push_same_day=False, fire_at=_FIRE) is None
