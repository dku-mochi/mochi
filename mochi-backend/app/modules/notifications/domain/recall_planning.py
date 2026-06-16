"""능동 회수 알림 플래너(P2) 도메인 — 값객체 + 포트.

정본 `journal/proactive-recall/notification-agent.md` §1·§2 / `schema.md` §1·§3.

아키텍처 결정(부모 Claude): tech-plan §4 는 "메인 Agent 가 needs_notification 판정"이라 하지만
eval-튜닝된 핵심 분석 경로(v21 system prompt / finalizeAnalysis 구조화 출력)는 **무손상**으로 둔다.
대신 분석 결과(intent_instances + importance)로부터 **결정적(LLM 아님) eligibility 게이트**가
"알림 가치 있는 신규/변경 intent" 만 통과시키고(= needs_notification 판정 대체), LLM 플래너는
eligible 건의 시점·시각·문구만 설계한다. 이로써 분석 경로를 건드리지 않는다(Surgical Changes).

프레임워크 import 금지(sqlalchemy/google/httpx 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
from uuid import UUID

from app.modules.notifications.domain.recall_plan import PlanKind


@dataclass(frozen=True, slots=True)
class EligibleCandidate:
    """eligibility 게이트를 통과한 알림 후보 1건 (intent 1개에 1:1).

    suggested_plan_kind 는 게이트의 보수적 추천 — LLM 플래너가 시점·시각·문구를 채운다.
    payload 의 anchor 값(date/deadline)은 캐시하지 않는다(schema.md §1): stages 는 심볼 참조이고
    cron 이 발송 때 최신 조회한다. 여기 anchor_date 는 LLM 컨텍스트용(긴급도·간격 판단)일 뿐이다.
    """

    source_intent_id: UUID
    source_item_id: UUID
    intent_type: str  # schedule | todo | knowledge
    suggested_plan_kind: PlanKind
    title: str | None
    label: str | None
    # 미래 기준점(있으면) — LLM 이 D-day 긴급도/간격을 판단하도록 컨텍스트로 전달. ISO date/datetime 문자열.
    anchor_value: str | None = None


@dataclass(frozen=True, slots=True)
class RecentItem:
    """최근/유사 저장 기록 1건 (LLM 맥락주입용 — 난사 억제·묶기 판단)."""

    title: str | None
    summary: str | None
    category: str | None
    created_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class PastNotification:
    """과거 발송 알림 1건. opened *시각* 만 신호다 — 안 누름 ≠ negative(notification-agent.md §6)."""

    title: str
    fire_at: datetime | None
    opened_at: datetime | None  # non-null = 양성 신호


@dataclass(frozen=True, slots=True)
class ScheduledNotification:
    """특정 날짜(KST)에 이미 예정된 알림 1건 — get_scheduled tool 응답(묶기·중복방지)."""

    title: str
    fire_at: datetime
    kind: str


@dataclass(slots=True)
class PlanningContext:
    """LLM 플래너에 주입하는 맥락. notification-agent.md §2.2.

    similar 가 비어 있을 수 있다(임베딩 미설정/미색인) — 그 경우 컨텍스트에서 생략(설계 허용).
    """

    now_kst: datetime
    recent: list[RecentItem] = field(default_factory=list)
    similar: list[RecentItem] = field(default_factory=list)
    past_notifications: list[PastNotification] = field(default_factory=list)


@dataclass(frozen=True, slots=True)
class PlannerDecision:
    """LLM 플래너의 finalize 출력 (구조화).

    stages 는 미검증 dict — 유스케이스가 `RecallPlanStages.model_validate(...).validate_for(...)`
    로 **삽입 전** 검증한다(malformed/adversarial 차단, schema.md §3).
    supersede_plan_id 가 있으면 같은 source_intent 의 기존 active plan 을 교체한다.
    """

    plan_kind: PlanKind
    stages: dict[str, Any]  # RecallPlanStages 모양 — 유스케이스가 검증
    generated_model: str  # 재현성 — 모델명+프롬프트버전(예: "gemini-3.1-flash-lite/recall_v1")
    supersede_plan_id: UUID | None = None


class RecallPlannerPort(ABC):
    """알림 설계 Agent(LLM) 추상화. 테스트는 stub 주입(고정 decision 반환).

    None 반환 = "이 후보는 알림 가치 없음/애매함" → plan 미생성("애매하면 안 보낸다", §3).
    """

    @abstractmethod
    async def plan(
        self,
        *,
        candidate: EligibleCandidate,
        context: PlanningContext,
        get_scheduled: "ScheduledLookup",
    ) -> PlannerDecision | None: ...


class ScheduledLookup(ABC):
    """`get_scheduled(date)` tool 의 백엔드 — 그날 예정 알림 조회(묶기·중복방지).

    포트로 분리해 LLM 어댑터가 모듈 경계를 넘지 않고 outbox/plan 을 조회하게 한다.
    """

    @abstractmethod
    async def for_date(self, *, owner_id: UUID, date_kst: str) -> list[ScheduledNotification]:
        """date_kst('YYYY-MM-DD') 에 fire 예정인 알림 목록(owner-scoped)."""


class RecallContextProviderPort(ABC):
    """맥락 수집 추상화 — 최근10 / 유사10(임베딩) / 과거알림10."""

    @abstractmethod
    async def gather(self, *, owner_id: UUID, mochi_item_id: UUID) -> PlanningContext: ...


@dataclass(frozen=True, slots=True)
class StoredPlan:
    """저장된 plan 의 식별 정보 — supersede 판정용(전체 row 불필요)."""

    id: UUID
    source_intent_id: UUID


class RecallPlanRepositoryPort(ABC):
    """notification_plan 영속화. owner-scoped, plan 폭증 방지(같은 intent 1 active)."""

    @abstractmethod
    async def find_active_by_intent(
        self, *, owner_id: UUID, source_intent_id: UUID
    ) -> StoredPlan | None:
        """같은 source_intent 의 active plan(있으면). 신규 생성 대신 supersede/skip 판정."""

    @abstractmethod
    async def insert_plan(
        self,
        *,
        owner_id: UUID,
        source_intent_id: UUID,
        source_item_id: UUID,
        plan_kind: PlanKind,
        stages: dict[str, Any],
        generated_model: str,
        next_eligible_at: datetime,
    ) -> UUID:
        """새 plan 1 row INSERT, 생성된 plan id 반환. status='active', dsl_version='1'."""

    @abstractmethod
    async def supersede(
        self, *, owner_id: UUID, old_plan_id: UUID, new_plan_id: UUID
    ) -> None:
        """기존 plan.status='superseded' + superseded_by=new (같은 트랜잭션).

        owner-scope + status='active' 가드로 cross-tenant update·이미 종료된 plan 재교체를 막는다
        (schema.md §4-3 owner 일관성). 이 시점엔 outbox 가 없어 outbox skip(schema.md §4-2)은
        P3 cron 몫(여기선 plan 만 교체)."""
