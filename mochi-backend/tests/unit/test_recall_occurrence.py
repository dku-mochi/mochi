"""능동 회수 알림 — occurrence-math 순수 단위테스트 (P3, DB 무관).

relative(offset 음/양·time_hint·whole-day vs T) / recurring(interval·max·until) /
spaced(opened→전진·dismissed→terminal·미반응→대기) + edge(과거 anchor→stale).
정본 schema.md §3·§4.
"""

from datetime import UTC, datetime, timedelta

from app.modules.notifications.application.recall_occurrence import (
    KST,
    SPACED_DONE,
    SPACED_WAIT,
    NextOccurrence,
    SpacedState,
    next_recurring_occurrence,
    next_relative_occurrence,
    next_spaced_occurrence,
    parse_iso_duration,
    resolve_anchor_time,
)
from app.modules.notifications.domain.recall_plan import (
    AnchorKind,
    Stage,
    Trigger,
    TriggerType,
)

_GRACE = timedelta(hours=6)


def _relative_stage(offset: str, *, time_hint: str | None = None, anchor: AnchorKind = AnchorKind.DEADLINE) -> Stage:
    return Stage(
        seq=1,
        trigger=Trigger(type=TriggerType.RELATIVE, anchor=anchor, offset=offset),
        time_hint=time_hint,
        content_template="{title}",
    )


def _recurring_stage(interval_days: int, *, max_occurrences: int | None = None) -> Stage:
    return Stage(
        seq=1,
        trigger=Trigger(type=TriggerType.RECURRING, interval_days=interval_days, max_occurrences=max_occurrences),
        content_template="{title}",
    )


def _spaced_stage(schedule_days: list[int]) -> Stage:
    return Stage(
        seq=1,
        trigger=Trigger(type=TriggerType.SPACED, schedule_days=schedule_days),
        content_template="{title}",
    )


# ---------- parse_iso_duration ----------


def test_parse_duration_negative_days():
    assert parse_iso_duration("-P7D") == timedelta(days=-7)


def test_parse_duration_positive_hours():
    assert parse_iso_duration("+PT2H") == timedelta(hours=2)


def test_parse_duration_weeks():
    assert parse_iso_duration("-P2W") == timedelta(days=-14)


def test_parse_duration_mixed_day_hour_minute():
    assert parse_iso_duration("-P1DT3H30M") == -(timedelta(days=1, hours=3, minutes=30))


def test_parse_duration_month_rejected():
    # 월/년은 정확한 일수 없어 미지원 — recall offset 에 안 쓰임.
    import pytest

    with pytest.raises(ValueError):
        parse_iso_duration("-P1M")


# ---------- resolve_anchor_time ----------


def test_resolve_saved_at_anchor_uses_created_at():
    saved = datetime(2026, 6, 16, 3, 0, tzinfo=UTC)
    out = resolve_anchor_time(anchor=AnchorKind.SAVED_AT, deadline_value=None, event_date_value=None, saved_at=saved)
    assert out == saved


def test_resolve_deadline_naive_interpreted_as_kst():
    out = resolve_anchor_time(
        anchor=AnchorKind.DEADLINE, deadline_value="2026-06-20T09:00", event_date_value=None,
        saved_at=datetime.now(UTC),
    )
    # 09:00 KST == 00:00 UTC
    assert out == datetime(2026, 6, 20, 0, 0, tzinfo=UTC)


def test_resolve_missing_value_returns_none():
    out = resolve_anchor_time(
        anchor=AnchorKind.DEADLINE, deadline_value=None, event_date_value=None, saved_at=datetime.now(UTC)
    )
    assert out is None


# ---------- relative ----------


def test_relative_negative_offset_with_time_part_exact():
    # T 포함 offset → 계산된 시각 그대로(time_hint 무시).
    anchor = datetime(2026, 6, 20, 0, 0, tzinfo=UTC)  # 09:00 KST
    now = datetime(2026, 6, 1, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("-PT2H"), anchor_time=anchor, now=now, grace=_GRACE, already_materialized=False
    )
    assert isinstance(occ, NextOccurrence)
    assert occ.occurrence_seq == 1
    assert occ.fire_at == anchor - timedelta(hours=2)
    assert occ.expires_at is None


def test_relative_whole_day_offset_applies_time_hint_kst():
    # whole-day(T 없음) offset → target 날짜의 time_hint(KST) 시각.
    anchor = datetime(2026, 6, 20, 0, 0, tzinfo=UTC)  # 2026-06-20 09:00 KST
    now = datetime(2026, 6, 1, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("-P3D", time_hint="19:00"), anchor_time=anchor, now=now, grace=_GRACE,
        already_materialized=False,
    )
    assert occ is not None
    # target date = 2026-06-17 (KST), time = 19:00 KST = 10:00 UTC
    assert occ.fire_at.astimezone(KST).hour == 19
    assert occ.fire_at.astimezone(KST).date().isoformat() == "2026-06-17"


def test_relative_whole_day_default_hour_when_no_hint():
    anchor = datetime(2026, 6, 20, 0, 0, tzinfo=UTC)
    now = datetime(2026, 6, 1, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("-P1D"), anchor_time=anchor, now=now, grace=_GRACE, already_materialized=False
    )
    assert occ is not None
    assert occ.fire_at.astimezone(KST).hour == 9  # 기본 9시


def test_relative_already_materialized_returns_none():
    anchor = datetime(2026, 6, 20, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("-P1D"), anchor_time=anchor, now=datetime(2026, 6, 1, tzinfo=UTC),
        grace=_GRACE, already_materialized=True,
    )
    assert occ is None


def test_relative_past_anchor_beyond_grace_sets_expires():
    # target 이 now-grace 보다 과거 → expires_at 세팅(워커가 stale skip).
    anchor = datetime(2026, 6, 1, 0, 0, tzinfo=UTC)
    now = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("-PT2H"), anchor_time=anchor, now=now, grace=_GRACE, already_materialized=False
    )
    assert occ is not None
    assert occ.expires_at is not None
    assert occ.fire_at < now - _GRACE


def test_relative_positive_offset():
    anchor = datetime(2026, 6, 20, 0, 0, tzinfo=UTC)
    now = datetime(2026, 6, 1, 0, 0, tzinfo=UTC)
    occ = next_relative_occurrence(
        stage=_relative_stage("+PT3H"), anchor_time=anchor, now=now, grace=_GRACE, already_materialized=False
    )
    assert occ is not None
    assert occ.fire_at == anchor + timedelta(hours=3)


# ---------- recurring ----------


def test_recurring_first_occurrence_is_seq0():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    occ = next_recurring_occurrence(stage=_recurring_stage(3), base=base, last_occurrence_seq=None, until_time=None)
    assert occ is not None
    assert occ.occurrence_seq == 0
    assert occ.fire_at == base + timedelta(days=3)


def test_recurring_advances_by_interval():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    occ = next_recurring_occurrence(stage=_recurring_stage(3), base=base, last_occurrence_seq=0, until_time=None)
    assert occ is not None
    assert occ.occurrence_seq == 1
    assert occ.fire_at == base + timedelta(days=6)


def test_recurring_stops_at_max_occurrences():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    # max=2 → seq 0,1 만. last=1 이면 next=2 >= 2 → None.
    occ = next_recurring_occurrence(
        stage=_recurring_stage(3, max_occurrences=2), base=base, last_occurrence_seq=1, until_time=None
    )
    assert occ is None


def test_recurring_stops_at_until_time():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    until = base + timedelta(days=5)  # seq0 fire=+3d(ok), seq1 fire=+6d(>until)
    occ = next_recurring_occurrence(stage=_recurring_stage(3), base=base, last_occurrence_seq=0, until_time=until)
    assert occ is None


# ---------- spaced ----------


def test_spaced_first_occurrence_from_base():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    out = next_spaced_occurrence(stage=_spaced_stage([3, 7, 18, 45]), base=base, last=None)
    assert isinstance(out, NextOccurrence)
    assert out.occurrence_seq == 0
    assert out.fire_at == base + timedelta(days=3)


def test_spaced_advances_from_opened_at_by_gap():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    opened = datetime(2026, 6, 20, 12, 0, tzinfo=UTC)
    last = SpacedState(occurrence_seq=0, sent_at=base, opened_at=opened, dismissed_at=None)
    out = next_spaced_occurrence(stage=_spaced_stage([3, 7, 18, 45]), base=base, last=last)
    assert isinstance(out, NextOccurrence)
    assert out.occurrence_seq == 1
    # gap = schedule[1]-schedule[0] = 7-3 = 4 days from opened_at(반응 기준, sent_at 아님).
    assert out.fire_at == opened + timedelta(days=4)


def test_spaced_dismissed_is_terminal():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    last = SpacedState(occurrence_seq=0, sent_at=base, opened_at=None, dismissed_at=datetime.now(UTC))
    out = next_spaced_occurrence(stage=_spaced_stage([3, 7, 18]), base=base, last=last)
    assert out == SPACED_DONE


def test_spaced_sent_but_no_reaction_waits():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    last = SpacedState(occurrence_seq=0, sent_at=base, opened_at=None, dismissed_at=None)
    out = next_spaced_occurrence(stage=_spaced_stage([3, 7, 18]), base=base, last=last)
    assert out == SPACED_WAIT  # 안누름≠negative, 전진 안 함(페널티 없음)


def test_spaced_exhausted_returns_none():
    base = datetime(2026, 6, 16, 0, 0, tzinfo=UTC)
    opened = datetime(2026, 6, 20, tzinfo=UTC)
    # 마지막 칸(seq=1, schedule 길이 2) opened 후 → 더 없음.
    last = SpacedState(occurrence_seq=1, sent_at=base, opened_at=opened, dismissed_at=None)
    out = next_spaced_occurrence(stage=_spaced_stage([3, 7]), base=base, last=last)
    assert out is None
