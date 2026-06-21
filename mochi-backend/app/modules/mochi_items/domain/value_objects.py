"""MochiItem intent 표현에 관한 value objects.

LLM(Vertex AI Gemini)이 한 캡쳐에 대해 출력하는 의도 instance 들(``IntentInstance``).
각 instance 는 저장되면 곧 active 인 1급 의도다 — 점수(applicability/confidence/threshold)·
위계(primary/secondary)·대표(representative)는 폐기됐다(2026-06-04 빅뱅, lab FINDINGS).
한 캡쳐가 같은 type 의 instance 를 여러 개 가질 수 있고(TODO 여러 개), 각 instance 는
독립 lifecycle 을 갖는다.

미확정 후보(``ReviewOption``)는 instance 가 아니다 — ``needs_review=true`` 일 때 사용자에게
제시되는 후보로, mochi_items.review_options JSONB 컬럼에 영속한다(PR-B 컬럼 승격).
"""

from dataclasses import dataclass, field
from enum import StrEnum
from uuid import UUID, uuid4

from app.shared.intent import Intent


class InstanceLifecycleKind(StrEnum):
    """intent instance 의 의미 lifecycle (완료/만료/decay).

    item 의 처리 파이프라인 상태(``LifecycleStateKind``)와 **직교**한다. instance 는 분석
    성공 시점에만 생성되므로 항상 ``active`` 로 태어난다.
    """

    ACTIVE = "active"
    DECAYING = "decaying"
    REVIEW_REQUESTED = "reviewRequested"
    ARCHIVED = "archived"


class ArchiveReason(StrEnum):
    SCHEDULE_ENDED = "scheduleEnded"
    TODO_COMPLETED = "todoCompleted"
    KNOWLEDGE_STALE = "knowledgeStale"
    USER_MANUAL = "userManual"


class AccessSource(StrEnum):
    """사용자가 상세를 연 **직전 화면(navigation origin)** — 접근 자체가 아니라 *어디서 왔나*.

    origin 이 의도를 인코딩한다: ``search``=사용자가 존재를 알고 의도적으로 찾음,
    ``chat``=모찌가 못 떠올린 걸 찾아줌(능동회수 성공), ``recall``/``notification``=모찌 능동 push.
    능동 회수 랭킹(최근 클릭한 기록 가중)에서 origin 별로 신호 강도를 다르게 쓰기 위한 차원.

    안정적 도메인 enum 이 아니라 *진화하는 분석 차원* — DB CheckConstraint 로 굳히지 않고
    API(Pydantic/OpenAPI) 레이어에서만 검증한다(origin 추가가 마이그레이션을 요구하지 않게).
    """

    HOME = "home"
    SEARCH = "search"
    CHAT = "chat"
    RECALL = "recall"
    NOTIFICATION = "notification"
    CALENDAR = "calendar"
    CATEGORY = "category"
    FAVORITES = "favorites"
    DIGEST = "digest"
    RELATED = "related"


@dataclass(frozen=True, slots=True)
class InstanceLifecycleState:
    kind: InstanceLifecycleKind = InstanceLifecycleKind.ACTIVE
    archive_reason: ArchiveReason | None = None


@dataclass(frozen=True, slots=True)
class IntentPayload:
    """instance 의 구조화 속성 — 전부 optional typed field.

    자유 object 가 아니라 공통 typed field 로 둔 이유: 열린 object 는 Gemini structured
    output 이 빈 객체를 내기 쉬웠다(lab FINDINGS §19). title/deadline 등은 typed 컬럼이 아니라
    이 payload 안에 보관하며, calendar/todo materialize 가 실제로 필요해질 때 파싱한다.
    """

    title: str | None = None
    date: str | None = None
    time: str | None = None
    # 기간형 일정의 끝 — date/time 은 시작 의미로 재해석(end_* 없으면 점 일정, 하위호환).
    end_date: str | None = None
    end_time: str | None = None
    deadline: str | None = None
    person: str | None = None
    topic: str | None = None
    url: str | None = None
    note: str | None = None


@dataclass(slots=True)
class IntentInstance:
    """LLM 이 한 캡쳐에서 펼친 의도 1개 — 1급(별도 ``intent_instances`` 테이블 행).

    저장돼 있으면 곧 active. 점수 없음(저장 자체가 applicable 의 증거).

    - ``intent_type``: 4-Intent 매핑. 위계 없음 — 같은 type 다중 허용.
    - ``payload``: 구조화 속성(typed optional).
    - ``label``: 사용자가 보게 될 한국어 라벨 (예: "구매 고민"). nil 이면 UI 가 intent.displayName 폴백.
    - ``lifecycle``: 의미 상태(active 기본). intent_type 별 차등 전이(``lifecycle_policy``).
    """

    intent_type: Intent
    payload: IntentPayload = field(default_factory=IntentPayload)
    label: str | None = None
    reasoning: str = ""
    lifecycle: InstanceLifecycleState = field(default_factory=InstanceLifecycleState)
    id: UUID = field(default_factory=uuid4)


@dataclass(frozen=True, slots=True)
class ReviewOption:
    """needs_review=true 일 때 사용자에게 제시하는 미확정 후보.

    instance 가 **아니다** — mochi_items.review_options JSONB 에 영속(PR-B 컬럼 승격). 사용자가
    고르면 그때 해당 type 의 ``IntentInstance`` 를 새로 생성한다.
    """

    intent_type: Intent
    label: str | None = None
    reasoning: str = ""
