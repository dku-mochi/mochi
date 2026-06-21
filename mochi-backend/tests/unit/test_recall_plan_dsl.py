"""능동 회수 알림 stages DSL — Trigger 검증 단위테스트 (M-1·M-2).

LLM 이 채우는 trigger 의 type별 필드 정합과 duration 유효성을 강제하는지 확인한다.
M-1: type 에 무관한 필드가 섞이면 거부 / M-2: 0·무의미 duration 거부.
"""

import pytest
from pydantic import ValidationError

from app.modules.notifications.domain.recall_plan import Trigger

# --- M-1: type별 무관 필드 거부 -------------------------------------------------


def test_relative_rejects_schedule_days():
    with pytest.raises(ValidationError):
        Trigger(type="relative", anchor="deadline", offset="-P7D", schedule_days=[3, 7])


def test_relative_rejects_interval_days():
    with pytest.raises(ValidationError):
        Trigger(type="relative", anchor="deadline", offset="-P7D", interval_days=3)


def test_recurring_rejects_anchor():
    with pytest.raises(ValidationError):
        Trigger(type="recurring", interval_days=3, anchor="deadline")


def test_recurring_rejects_offset():
    with pytest.raises(ValidationError):
        Trigger(type="recurring", interval_days=3, offset="-P7D")


def test_spaced_rejects_interval_days():
    with pytest.raises(ValidationError):
        Trigger(type="spaced", schedule_days=[3, 7], interval_days=3)


def test_spaced_rejects_until_anchor():
    with pytest.raises(ValidationError):
        Trigger(type="spaced", schedule_days=[3, 7], until_anchor="deadline")


# --- 정상 케이스(회귀 방지) ---------------------------------------------------


def test_relative_minimal_ok():
    t = Trigger(type="relative", anchor="event_date", offset="-P15D")
    assert t.offset == "-P15D"


def test_recurring_with_optional_fields_ok():
    t = Trigger(type="recurring", interval_days=3, max_occurrences=2, until_anchor="deadline")
    assert t.max_occurrences == 2
    assert t.until_anchor is not None


def test_spaced_minimal_ok():
    t = Trigger(type="spaced", schedule_days=[3, 7, 18, 45])
    assert t.schedule_days == [3, 7, 18, 45]


# --- M-2: 0·무의미 duration 거부 ----------------------------------------------


@pytest.mark.parametrize("offset", ["+P0D", "-PT0S", "P0D", "+P0DT0H0M0S"])
def test_zero_duration_rejected(offset: str):
    with pytest.raises(ValidationError):
        Trigger(type="relative", anchor="deadline", offset=offset)


@pytest.mark.parametrize("offset", ["-P15D", "-PT2H", "+P3D", "-P1W"])
def test_nonzero_duration_accepted(offset: str):
    t = Trigger(type="relative", anchor="deadline", offset=offset)
    assert t.offset == offset
