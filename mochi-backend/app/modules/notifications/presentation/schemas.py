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


class RecallFeedEntry(BaseModel):
    """능동 회수 1건 — iOS ``RecallEntry`` 표시모델 매핑(P5b). 홈 한 칸·자세히 목록·알림 landing 공용.

    UI 전용(color/symbol/grad)은 제외 — iOS 가 ``reason`` → 색/아이콘 매핑. 트랙 A/B 에선 피드가
    "다시 볼 지식"(active spaced plan knowledge)뿐이라 ``kind``="knowledge", ``reason``="fadingValue",
    ``related``=[]·``relatedCount``=1(트랙 C 관련/맥락 후속). ``oneline``/``gist`` 는 summary 분할.
    """

    item_id: UUID = Field(alias="itemId")
    kind: str  # 현재 항상 "knowledge"(트랙 A/B)
    reason: str  # "fadingValue" | "relatedCluster" | "revisitedOften" | "linkedToRecent"
    title: str
    oneline: str  # summary 요지 1줄(미리보기). 없으면 ""
    source: str  # ingest channel 문자열
    saved_at: UtcDateTime = Field(alias="savedAt")
    gist: list[str] = Field(default_factory=list)  # 상세 핵심 bullet(summary 기반). 없으면 []
    related: list[str] = Field(default_factory=list)  # 트랙 C 후속 — 현재 항상 []
    related_count: int = Field(alias="relatedCount")  # 현재 항상 1
    # 그 항목의 최근 sent outbox event_id(없으면 null) — 알림 landing 역참조·reaction 보고용.
    recall_event_id: UUID | None = Field(default=None, alias="recallEventID")

    model_config = {"populate_by_name": True}


class RecallFeedResponse(BaseModel):
    """홈 회수 피드 — owner 의 다시 볼 지식 목록. 빈손이면 entries=[](cold-start 정상)."""

    entries: list[RecallFeedEntry] = Field(default_factory=list)
