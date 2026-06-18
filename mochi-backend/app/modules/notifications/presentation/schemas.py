"""POST /devices/push-token + POST /recall/events/{id}/reaction 의 Pydantic 스키마.

iOS DTO 와 1:1, camelCase alias.
"""

from uuid import UUID

from pydantic import BaseModel, Field

from app.core.schema import UtcDateTime
from app.modules.notifications.domain.entities import APNsEnvironment, PushTokenType
from app.modules.notifications.domain.recall_reaction import ReactionKind


class RegisterPushTokenRequest(BaseModel):
    """단말(apns_device) 또는 Live Activity push-to-start(la_start) push 토큰 등록 요청."""

    token: str = Field(min_length=1, max_length=512)
    token_type: PushTokenType = Field(alias="tokenType")
    # 클라(iOS)가 자기 빌드 환경을 명시한다 — Xcode=sandbox, TestFlight/App Store=production.
    # 토큰은 환경에 묶여 잘못 매칭 시 BadDeviceToken → required(서버 기본값 없음).
    environment: APNsEnvironment
    mochi_item_id: UUID | None = Field(default=None, alias="mochiItemID")

    model_config = {"populate_by_name": True}


class RecordRecallReactionRequest(BaseModel):
    """알림 반응 보고 — iOS 가 알림 탭/dismiss/그만 시 `recallEventID`(=outbox.event_id)로 보고.

    opened=양성, dismissed=soft 부정, stop="이 기억 그만" 영구(plan cancel). 신호 의미는
    notification-agent.md §6, 반응→상태전이 1:1 은 ux-ui.md §4.
    """

    reaction: ReactionKind

    model_config = {"populate_by_name": True}


class RelatedItem(BaseModel):
    """관련 기억 1건(트랙 C 상세 "관련 N개"). 탭 시 그 항목 상세로 — ``itemId`` 운반."""

    item_id: UUID = Field(alias="itemId")
    title: str
    oneline: str

    model_config = {"populate_by_name": True}


class RecallFeedEntry(BaseModel):
    """능동 회수 1건 — iOS ``RecallEntry`` 표시모델 매핑(P5b). 홈 한 칸·자세히 목록·알림 landing 공용.

    UI 전용(color/symbol/grad)은 제외 — iOS 가 ``reason`` → 색/아이콘 매핑. 트랙 A(spaced)는
    ``kind``="knowledge"/``reason``="fadingValue"/``related``=[]/``relatedCount``=1, 트랙 C(recall)는
    ``kind``="recall"/``reason``="linkedToRecent"/``related``=관련 기억 N개. ``oneline``/``gist`` 는
    summary 분할.
    """

    item_id: UUID = Field(alias="itemId")
    kind: str  # "knowledge"(트랙 A spaced) | "recall"(트랙 C)
    reason: str  # "fadingValue" | "relatedCluster" | "revisitedOften" | "linkedToRecent"
    title: str
    oneline: str  # summary 요지 1줄(미리보기). 없으면 ""
    source: str  # ingest channel 문자열
    saved_at: UtcDateTime = Field(alias="savedAt")
    gist: list[str] = Field(default_factory=list)  # 상세 핵심 bullet(summary 기반). 없으면 []
    related: list[RelatedItem] = Field(default_factory=list)  # 트랙 C 관련 기억(spaced 는 [])
    related_count: int = Field(alias="relatedCount")  # spaced=1, recall=관련 개수
    # 그 항목의 최근 sent outbox event_id(없으면 null) — 알림 landing 역참조·reaction 보고용.
    recall_event_id: UUID | None = Field(default=None, alias="recallEventID")

    model_config = {"populate_by_name": True}


class RecallFeedResponse(BaseModel):
    """홈 회수 피드 — owner 의 다시 볼 지식 목록. 빈손이면 entries=[](cold-start 정상)."""

    entries: list[RecallFeedEntry] = Field(default_factory=list)


class UpcomingNotificationEntry(BaseModel):
    """홈탭 "예정 알림" 1건 — 모찌가 보낼 예정인 미래 알림(마감/일정). iOS ``UpcomingNotificationDTO`` 1:1.

    ``eventId`` 가 veto/reschedule 타겟 키(=outbox.event_id). ``fireAt`` 은 현재 유효 발송 예정 시각,
    ``originalFireAt`` 은 사용자가 옮겼으면 모찌 원안(없으면 null=미조정). ``kind``="deadline"|"nudge".
    """

    event_id: UUID = Field(alias="eventId")
    kind: str
    fire_at: UtcDateTime = Field(alias="fireAt")
    title: str
    body: str
    original_fire_at: UtcDateTime | None = Field(default=None, alias="originalFireAt")
    item_id: UUID | None = Field(default=None, alias="itemId")
    intent_id: UUID | None = Field(default=None, alias="intentId")

    model_config = {"populate_by_name": True}


class UpcomingNotificationsResponse(BaseModel):
    """홈 "예정 알림" 목록 — fire_at 오름차순. 빈손이면 entries=[](정상 — 예정 알림 없음)."""

    entries: list[UpcomingNotificationEntry] = Field(default_factory=list)


class RescheduleUpcomingRequest(BaseModel):
    """예정 알림 시간 조정 — 사용자가 정한 새 발송 시각(프리셋·DatePicker 공용). 과거 불가(422)."""

    fire_at: UtcDateTime = Field(alias="fireAt")

    model_config = {"populate_by_name": True}
