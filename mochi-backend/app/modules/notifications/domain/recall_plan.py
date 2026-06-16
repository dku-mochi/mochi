"""능동 회수 알림 stages DSL — Pydantic 검증 모델. 정본 `journal/proactive-recall/schema.md` §3.

LLM 플래너가 `notification_plan.stages`(JSONB) 를 생성하므로 **삽입 전 검증 필수**(malformed/adversarial
방지). trigger 3종(relative/recurring/spaced) + 시각·문구·무게. anchor↔plan_kind 정합은 plan_kind 를
받아 검증하는 `RecallPlanStages.validate_for(plan_kind)` 가 강제한다.

프레임워크 import 금지 규약(notifications.domain)을 따르되, Pydantic 은 다른 domain 모듈(auth/
mochi_items/conversations)에서도 도메인 검증에 쓰는 표준이라 허용 범위다.
"""

import re
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, model_validator


class TriggerType(StrEnum):
    """stage trigger 의 종류."""

    RELATIVE = "relative"  # 고정 기준점(anchor) 대비 오프셋 — 다단/상대시간
    RECURRING = "recurring"  # 마감 없는 주기 넛지
    SPACED = "spaced"  # 지식 정착(반응 시 다음 칸 전진)


class AnchorKind(StrEnum):
    """relative trigger 의 기준점 (닫힌 enum). plan_kind 와 정합 강제."""

    DEADLINE = "deadline"
    EVENT_DATE = "event_date"
    SAVED_AT = "saved_at"


class ImportanceHint(StrEnum):
    """중요도 우선 가드 입력."""

    HEAVY = "heavy"
    LIGHT = "light"


class PlanKind(StrEnum):
    """notification_plan.plan_kind (3종)."""

    DEADLINE_BACKOFF = "deadline_backoff"
    RECURRING_NUDGE = "recurring_nudge"
    SPACED = "spaced"


class OutboxKind(StrEnum):
    """notification_outbox.kind (4종, push 빌더 분기)."""

    DEADLINE = "deadline"
    NUDGE = "nudge"
    SPACED = "spaced"
    RECALL = "recall"  # 트랙 C 직행(plan 없음)


# plan_kind(3종) → outbox.kind(4종) 매핑. recall 은 plan 없이 직행이라 매핑 대상 아님. schema.md §3 표.
_PLAN_TO_OUTBOX_KIND: dict[PlanKind, OutboxKind] = {
    PlanKind.DEADLINE_BACKOFF: OutboxKind.DEADLINE,
    PlanKind.RECURRING_NUDGE: OutboxKind.NUDGE,
    PlanKind.SPACED: OutboxKind.SPACED,
}

# plan_kind ↔ trigger.type 정합. deadline_backoff 만 relative, 나머지는 1:1.
_PLAN_TO_TRIGGER_TYPE: dict[PlanKind, TriggerType] = {
    PlanKind.DEADLINE_BACKOFF: TriggerType.RELATIVE,
    PlanKind.RECURRING_NUDGE: TriggerType.RECURRING,
    PlanKind.SPACED: TriggerType.SPACED,
}

# deadline_backoff(relative) 에서 허용되는 anchor. saved_at 은 마감 역산 의미가 없어 제외.
_DEADLINE_BACKOFF_ANCHORS: frozenset[AnchorKind] = frozenset(
    {AnchorKind.DEADLINE, AnchorKind.EVENT_DATE}
)

# ISO-8601 duration 부호부 — `-P7D`, `-PT2H`, `+P3D`. 주(W)는 다른 요소와 못 섞이는 ISO 규칙 반영.
_DURATION_RE = re.compile(
    r"^[+-]P(?:\d+W|(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+S)?)?)$"
)
# 모든 숫자 component 를 뽑아 0-only 인지 판정(`+P0D`, `-PT0S` 등 무의미 duration 거부).
_DURATION_NUMS_RE = re.compile(r"\d+")


def _is_valid_duration(value: str) -> bool:
    """ISO-8601 duration(부호부) 유효성. 최소 1개 component 가 > 0 이어야 한다.

    `+P` 단독뿐 아니라 `+P0D`/`-PT0S` 같은 0/무의미 duration 도 거부(schedule 의미 없음).
    """
    if not _DURATION_RE.match(value):
        return False
    return any(int(n) > 0 for n in _DURATION_NUMS_RE.findall(value))


def outbox_kind_for(plan_kind: PlanKind) -> OutboxKind:
    """plan_kind 에 대응하는 outbox.kind. schema.md §3 매핑표."""
    return _PLAN_TO_OUTBOX_KIND[plan_kind]


class Trigger(BaseModel):
    """stage 의 발생 규칙. type 별로 필요한 필드가 다르다(아래 model_validator 가 강제). schema.md §3."""

    model_config = ConfigDict(extra="forbid")  # adversarial 키 차단

    type: TriggerType
    # [relative] 고정 기준점 대비 오프셋
    anchor: AnchorKind | None = None
    offset: str | None = None  # ISO-8601 duration: -P7D, -PT2H, +P3D
    # [recurring] 마감 없는 주기 넛지
    interval_days: int | None = None
    max_occurrences: int | None = None
    until_anchor: AnchorKind | None = None  # null=무한
    # [spaced] 지식 정착(반응 시 다음 칸 전진)
    schedule_days: list[int] | None = None

    @model_validator(mode="after")
    def _check_type_fields(self) -> "Trigger":
        # 각 type 은 자기 필드만 — 무관 필드는 None 이어야 한다(LLM 이 type 에 안 맞는 필드를 섞어도 컷).
        if self.type is TriggerType.RELATIVE:
            if self.anchor is None or self.offset is None:
                raise ValueError("relative trigger requires anchor and offset")
            if not _is_valid_duration(self.offset):
                raise ValueError(f"offset is not a valid ISO-8601 duration: {self.offset!r}")
            if (
                self.interval_days is not None
                or self.max_occurrences is not None
                or self.until_anchor is not None
                or self.schedule_days is not None
            ):
                raise ValueError("relative trigger allows only anchor and offset")
        elif self.type is TriggerType.RECURRING:
            if self.interval_days is None:
                raise ValueError("recurring trigger requires interval_days")
            if self.interval_days <= 0:
                raise ValueError("interval_days must be positive")
            if self.max_occurrences is not None and self.max_occurrences <= 0:
                raise ValueError("max_occurrences must be positive")
            if self.anchor is not None or self.offset is not None or self.schedule_days is not None:
                raise ValueError(
                    "recurring trigger allows only interval_days, max_occurrences, until_anchor"
                )
        elif self.type is TriggerType.SPACED:
            if not self.schedule_days:
                raise ValueError("spaced trigger requires non-empty schedule_days")
            if any(d <= 0 for d in self.schedule_days):
                raise ValueError("schedule_days must be positive")
            if (
                self.anchor is not None
                or self.offset is not None
                or self.interval_days is not None
                or self.max_occurrences is not None
                or self.until_anchor is not None
            ):
                raise ValueError("spaced trigger allows only schedule_days")
        return self


class Stage(BaseModel):
    """stages 배열의 한 단계. nested trigger + 시각/문구/무게."""

    model_config = ConfigDict(extra="forbid")

    seq: int
    trigger: Trigger
    time_hint: str | None = None  # "19:00" — null 이면 cron 기본 윈도우
    content_template: str
    importance_hint: ImportanceHint | None = None


class RecallPlanStages(BaseModel):
    """notification_plan.stages JSONB 루트. dsl_version 고정 + stage 목록."""

    model_config = ConfigDict(extra="forbid")

    dsl_version: Literal["1"]
    stages: list[Stage]

    @model_validator(mode="after")
    def _check_non_empty(self) -> "RecallPlanStages":
        if not self.stages:
            raise ValueError("stages must be non-empty")
        return self

    def validate_for(self, plan_kind: PlanKind) -> "RecallPlanStages":
        """plan_kind ↔ stage trigger/anchor 정합을 강제한다.

        모든 stage 의 trigger_type 이 plan_kind 와 맞아야 하고, deadline_backoff 의 anchor 는
        {deadline, event_date} 로 제한된다. 위반 시 ValueError.
        """
        expected = _PLAN_TO_TRIGGER_TYPE[plan_kind]
        for stage in self.stages:
            if stage.trigger.type is not expected:
                raise ValueError(
                    f"plan_kind={plan_kind} requires trigger.type={expected}, "
                    f"got {stage.trigger.type} at seq={stage.seq}"
                )
            if (
                plan_kind is PlanKind.DEADLINE_BACKOFF
                and stage.trigger.anchor not in _DEADLINE_BACKOFF_ANCHORS
            ):
                raise ValueError(
                    f"deadline_backoff anchor must be one of {sorted(_DEADLINE_BACKOFF_ANCHORS)}, "
                    f"got {stage.trigger.anchor} at seq={stage.seq}"
                )
        return self
