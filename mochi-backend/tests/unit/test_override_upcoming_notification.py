"""Reschedule/Veto Upcoming 단위테스트 — 과거 거부·404·plan cancel 재사용.

repository 스텁으로 application 분기만 본다. atomic UPDATE 가드(pending+fire_at>now, COALESCE,
RETURNING plan_id)의 실제 SQL 은 PostgresUpcomingOverrideRepository 코드리뷰가 담당.
"""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.notifications.application.override_upcoming_notification import (
    PastFireAtError,
    RescheduleUpcomingCommand,
    RescheduleUpcomingNotification,
    VetoUpcomingCommand,
    VetoUpcomingNotification,
)

_OWNER = uuid4()


class _OverrideRepo:
    def __init__(self, *, reschedule_rowcount: int = 1, veto_result=(1, None, None)) -> None:
        self._reschedule_rowcount = reschedule_rowcount
        self._veto_result = veto_result
        self.reschedule_calls: list[tuple] = []
        self.veto_calls: list[tuple] = []

    async def reschedule(self, *, event_id, owner_id, new_fire_at) -> int:  # type: ignore[no-untyped-def]
        self.reschedule_calls.append((event_id, owner_id, new_fire_at))
        return self._reschedule_rowcount

    async def veto_pending(self, *, event_id, owner_id):  # type: ignore[no-untyped-def]
        self.veto_calls.append((event_id, owner_id))
        return self._veto_result


class _ReactionsRepo:
    def __init__(self) -> None:
        self.cancelled: list[tuple] = []
        self.bumped: list[tuple] = []

    async def cancel_plan(self, *, plan_id, owner_id) -> None:  # type: ignore[no-untyped-def]
        self.cancelled.append((plan_id, owner_id))

    async def bump_plan_next_eligible(self, *, plan_id, owner_id) -> None:  # type: ignore[no-untyped-def]
        self.bumped.append((plan_id, owner_id))


# ---------- reschedule ----------


async def test_reschedule_future_calls_repo() -> None:
    repo = _OverrideRepo(reschedule_rowcount=1)
    future = datetime.now(UTC) + timedelta(days=1)
    await RescheduleUpcomingNotification(override=repo).execute(
        RescheduleUpcomingCommand(owner_id=_OWNER, event_id=uuid4(), new_fire_at=future)
    )
    assert len(repo.reschedule_calls) == 1


async def test_reschedule_past_raises_and_skips_repo() -> None:
    repo = _OverrideRepo()
    past = datetime(2020, 1, 1, tzinfo=UTC)
    with pytest.raises(PastFireAtError):
        await RescheduleUpcomingNotification(override=repo).execute(
            RescheduleUpcomingCommand(owner_id=_OWNER, event_id=uuid4(), new_fire_at=past)
        )
    assert repo.reschedule_calls == []  # 검증 실패 → UPDATE 미시도


async def test_reschedule_missing_raises_not_found() -> None:
    repo = _OverrideRepo(reschedule_rowcount=0)  # 남의 event·이미 발송
    future = datetime.now(UTC) + timedelta(days=1)
    with pytest.raises(NotFoundError):
        await RescheduleUpcomingNotification(override=repo).execute(
            RescheduleUpcomingCommand(owner_id=_OWNER, event_id=uuid4(), new_fire_at=future)
        )


# ---------- veto ----------


async def test_veto_deadline_with_plan_cancels_plan() -> None:
    plan_id = uuid4()
    repo = _OverrideRepo(veto_result=(1, plan_id, "deadline"))
    reactions = _ReactionsRepo()
    await VetoUpcomingNotification(override=repo, reactions=reactions).execute(
        VetoUpcomingCommand(owner_id=_OWNER, event_id=uuid4())
    )
    assert reactions.cancelled == [(plan_id, _OWNER)]
    assert reactions.bumped == []


async def test_veto_spaced_bumps_next_eligible_not_cancel() -> None:
    # spaced veto = "이번 회차만 건너뛰기" — plan cancel 대신 next_eligible bump(다음 회차 전진).
    plan_id = uuid4()
    repo = _OverrideRepo(veto_result=(1, plan_id, "spaced"))
    reactions = _ReactionsRepo()
    await VetoUpcomingNotification(override=repo, reactions=reactions).execute(
        VetoUpcomingCommand(owner_id=_OWNER, event_id=uuid4())
    )
    assert reactions.bumped == [(plan_id, _OWNER)]
    assert reactions.cancelled == []


async def test_veto_without_plan_skips_both() -> None:
    repo = _OverrideRepo(veto_result=(1, None, "recall"))
    reactions = _ReactionsRepo()
    await VetoUpcomingNotification(override=repo, reactions=reactions).execute(
        VetoUpcomingCommand(owner_id=_OWNER, event_id=uuid4())
    )
    assert reactions.cancelled == []
    assert reactions.bumped == []


async def test_veto_missing_raises_not_found() -> None:
    repo = _OverrideRepo(veto_result=(0, None, None))
    reactions = _ReactionsRepo()
    with pytest.raises(NotFoundError):
        await VetoUpcomingNotification(override=repo, reactions=reactions).execute(
            VetoUpcomingCommand(owner_id=_OWNER, event_id=uuid4())
        )
    assert reactions.cancelled == []
    assert reactions.bumped == []
