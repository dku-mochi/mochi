"""능동 회수 알림 — PlanRecallNotifications 유스케이스 스모크테스트 (P2, 실제 Vertex 호출 없음).

LLM 포트를 stub(고정 decision)으로 주입해 stages 검증 통과 → 1 row 영속, supersede 동작,
validate_for 위반 stub 은 plan 미생성을 확인한다.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy.exc import IntegrityError

from app.modules.mochi_items.domain.value_objects import IntentInstance, IntentPayload
from app.modules.notifications.application.plan_recall_notifications import (
    PlanRecallNotifications,
)
from app.modules.notifications.domain.recall_plan import PlanKind
from app.modules.notifications.domain.recall_planning import (
    PlannerDecision,
    PlanningContext,
    StoredPlan,
)
from app.shared.intent import Intent

_NOW = datetime.now(UTC)
_FUTURE = "2027-01-01"


# --- 고정 stub들 ---------------------------------------------------------------


class _StubPlanner:
    """고정 decision 반환. decision=None 이면 "참는다"."""

    def __init__(self, decision: PlannerDecision | None) -> None:
        self._decision = decision
        self.calls = 0

    async def plan(self, *, candidate, context, get_scheduled):
        self.calls += 1
        return self._decision


class _StubContext:
    async def gather(self, *, owner_id, mochi_item_id) -> PlanningContext:
        return PlanningContext(now_kst=_NOW)


class _StubScheduled:
    async def for_date(self, *, owner_id, date_kst):
        return []


class _FakeRepo:
    """in-memory plan repo — insert/find_active/supersede 의 효과를 기록한다."""

    def __init__(self, *, existing: StoredPlan | None = None) -> None:
        self._existing = existing
        self.inserted: list[dict] = []
        self.superseded: list[tuple[UUID, UUID]] = []

    async def find_active_by_intent(self, *, owner_id, source_intent_id) -> StoredPlan | None:
        return self._existing

    async def insert_plan(self, *, owner_id, source_intent_id, source_item_id, plan_kind, stages, generated_model, next_eligible_at) -> UUID:
        new_id = uuid4()
        self.inserted.append(
            {
                "id": new_id,
                "source_intent_id": source_intent_id,
                "plan_kind": plan_kind,
                "stages": stages,
                "generated_model": generated_model,
            }
        )
        return new_id

    async def supersede(self, *, owner_id, old_plan_id, new_plan_id) -> None:
        self.superseded.append((old_plan_id, new_plan_id))


def _schedule_instance() -> IntentInstance:
    return IntentInstance(intent_type=Intent.SCHEDULE, payload=IntentPayload(title="토익 시험", date=_FUTURE))


def _valid_deadline_decision() -> PlannerDecision:
    return PlannerDecision(
        plan_kind=PlanKind.DEADLINE_BACKOFF,
        stages={
            "dsl_version": "1",
            "stages": [
                {
                    "seq": 1,
                    "trigger": {"type": "relative", "anchor": "event_date", "offset": "-P7D"},
                    "content_template": "토익 시험 7일 남았어요",
                    "importance_hint": "heavy",
                }
            ],
        },
        generated_model="gemini-3.1-flash-lite/recall_v1",
    )


def _make(planner, repo) -> PlanRecallNotifications:
    return PlanRecallNotifications(
        planner=planner,
        context_provider=_StubContext(),
        repository=repo,
        scheduled_lookup=_StubScheduled(),
    )


# --- 테스트 -------------------------------------------------------------------


async def test_valid_decision_persists_one_plan():
    repo = _FakeRepo()
    use_case = _make(_StubPlanner(_valid_deadline_decision()), repo)
    created = await use_case.run(
        owner_id=uuid4(), mochi_item_id=uuid4(), intent_instances=(_schedule_instance(),)
    )
    assert created == 1
    assert len(repo.inserted) == 1
    assert repo.inserted[0]["plan_kind"] is PlanKind.DEADLINE_BACKOFF
    assert repo.inserted[0]["stages"]["dsl_version"] == "1"
    assert repo.superseded == []


async def test_existing_active_plan_is_superseded():
    existing = StoredPlan(id=uuid4(), source_intent_id=uuid4())
    repo = _FakeRepo(existing=existing)
    use_case = _make(_StubPlanner(_valid_deadline_decision()), repo)
    created = await use_case.run(
        owner_id=uuid4(), mochi_item_id=uuid4(), intent_instances=(_schedule_instance(),)
    )
    assert created == 1
    assert len(repo.superseded) == 1
    old_id, new_id = repo.superseded[0]
    assert old_id == existing.id
    assert new_id == repo.inserted[0]["id"]


async def test_planner_decline_creates_no_plan():
    repo = _FakeRepo()
    use_case = _make(_StubPlanner(None), repo)
    created = await use_case.run(
        owner_id=uuid4(), mochi_item_id=uuid4(), intent_instances=(_schedule_instance(),)
    )
    assert created == 0
    assert repo.inserted == []


async def test_invalid_stages_creates_no_plan():
    # validate_for 위반: deadline_backoff 인데 trigger.type=spaced → 검증 실패 → plan 미생성(로깅만).
    bad = PlannerDecision(
        plan_kind=PlanKind.DEADLINE_BACKOFF,
        stages={
            "dsl_version": "1",
            "stages": [
                {
                    "seq": 1,
                    "trigger": {"type": "spaced", "schedule_days": [3, 7]},
                    "content_template": "x",
                }
            ],
        },
        generated_model="m/recall_v1",
    )
    repo = _FakeRepo()
    use_case = _make(_StubPlanner(bad), repo)
    created = await use_case.run(
        owner_id=uuid4(), mochi_item_id=uuid4(), intent_instances=(_schedule_instance(),)
    )
    assert created == 0
    assert repo.inserted == []


class _ConflictRepo(_FakeRepo):
    """insert_plan 이 부분 UNIQUE 충돌(동시 워커)을 시뮬레이트 — IntegrityError 발생."""

    async def insert_plan(self, *, owner_id, source_intent_id, source_item_id, plan_kind, stages, generated_model, next_eligible_at) -> UUID:
        raise IntegrityError("INSERT", {}, Exception("duplicate active plan"))


async def test_concurrent_active_plan_conflict_is_skipped():
    # H-3: 같은 (owner, source_intent) active plan 부분 UNIQUE 충돌 → insert IntegrityError →
    # 유스케이스가 크래시·루프 없이 skip(best-effort). 생성 0, supersede 미실행.
    repo = _ConflictRepo()
    use_case = _make(_StubPlanner(_valid_deadline_decision()), repo)
    created = await use_case.run(
        owner_id=uuid4(), mochi_item_id=uuid4(), intent_instances=(_schedule_instance(),)
    )
    assert created == 0
    assert repo.superseded == []


async def test_no_eligible_candidates_skips_llm():
    # memo only → eligibility 게이트가 빈 결과 → LLM 미호출.
    planner = _StubPlanner(_valid_deadline_decision())
    repo = _FakeRepo()
    use_case = _make(planner, repo)
    created = await use_case.run(
        owner_id=uuid4(),
        mochi_item_id=uuid4(),
        intent_instances=(IntentInstance(intent_type=Intent.MEMO, payload=IntentPayload(title="메모")),),
    )
    assert created == 0
    assert planner.calls == 0
    assert repo.inserted == []
