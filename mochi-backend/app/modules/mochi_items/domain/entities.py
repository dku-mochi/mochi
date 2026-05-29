from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID, uuid4

from app.modules.mochi_items.domain.value_objects import IntentClassification
from app.shared.intent import Intent


class IngestChannel(StrEnum):
    KAKAO_TALK = "kakaoTalk"
    INSTAGRAM = "instagram"
    YOUTUBE = "youtube"
    SAFARI = "safari"
    SCREENSHOT = "screenshot"
    APP_INTENT = "appIntent"
    APP_SHARE_SHEET = "appShareSheet"
    APP_DIRECT_INPUT = "appDirectInput"
    UNKNOWN = "unknown"


@dataclass(frozen=True, slots=True)
class ImageRef:
    """캡처에 첨부된 이미지의 도메인 표현. iOS ``CoreDomain.ImageRef`` 와 1:1.

    - ``sha256`` 는 64-char hex (소문자). 중복 감지·무결성 검증에 사용.
    - ``object_key`` 는 백엔드가 S3/GCS 업로드 후 부여하는 storage key. iOS가 보낸 시점에는 nil 가능.
    """

    sha256: str
    mime_type: str
    byte_size: int
    object_key: str | None = None
    id: UUID = field(default_factory=uuid4)


@dataclass(frozen=True, slots=True)
class IngestSource:
    channel: IngestChannel
    url: str | None = None
    text: str | None = None
    image_refs: tuple[ImageRef, ...] = ()
    user_memo: str | None = None
    captured_at: datetime = field(default_factory=lambda: datetime.utcnow())
    id: UUID = field(default_factory=uuid4)

    @property
    def has_user_intent_signal(self) -> bool:
        return bool(self.user_memo)


# ---------- Lifecycle ----------


class LifecycleStateKind(StrEnum):
    INGESTED = "ingested"
    ANALYZING = "analyzing"
    ACTIVE = "active"
    DECAYING = "decaying"
    REVIEW_REQUESTED = "reviewRequested"
    ARCHIVED = "archived"
    FAILED = "failed"


class ArchiveReason(StrEnum):
    SCHEDULE_ENDED = "scheduleEnded"
    TODO_COMPLETED = "todoCompleted"
    KNOWLEDGE_STALE = "knowledgeStale"
    USER_MANUAL = "userManual"


@dataclass(frozen=True, slots=True)
class LifecycleState:
    kind: LifecycleStateKind
    archive_reason: ArchiveReason | None = None
    failure_reason: str | None = None

    @classmethod
    def ingested(cls) -> "LifecycleState":
        return cls(kind=LifecycleStateKind.INGESTED)

    @classmethod
    def archived(cls, reason: ArchiveReason) -> "LifecycleState":
        return cls(kind=LifecycleStateKind.ARCHIVED, archive_reason=reason)


# ---------- Sync ----------


@dataclass(frozen=True, slots=True)
class SyncState:
    kind: Literal["pending", "uploaded", "calendar_synced", "reminder_synced", "failed"]
    detail: str | None = None


# ---------- MochiItem (aggregate root) ----------


@dataclass(slots=True)
class MochiItem:
    """MochiItem aggregate root — URL·이미지·링크를 통합한 모찌 항목.

    Intent 표현:
    - ``intent``: primary — 알림에서 사용자에게 가장 먼저 제시될 의도.
      분류 전 일반 ingestion 경로의 ``MEMO`` 는 unclassified fallback 으로 두는 값이며,
      "사용자 의도 = 메모" 라는 판정이 아니다. 집계 시 ``confidence`` 와 함께 해석.
    - ``secondary_intents``: applicability 내림차순의 보조 의도. primary 와 중복 불가.
    - ``intent_applicability``: 각 Intent → 적용 강도 (0.0-1.0). 후보에 등장하지 않은
      intent 는 키에 포함되지 않는다.
    """

    id: UUID
    source: IngestSource
    intent: Intent = Intent.MEMO
    secondary_intents: tuple[Intent, ...] = ()
    intent_applicability: Mapping[Intent, float] = field(default_factory=dict)
    # LLM 이 펼친 use case 후보 (홈 "헷갈려요" 카드·Live Activity 버튼의 원천).
    # applicability 가 confidence/multi-intent 판정의 단일 원천. worker 가 비동기로 채운다.
    intent_candidates: tuple[IntentClassification, ...] = ()
    summary: str | None = None
    importance: int = 3
    confidence: float = 0.0
    model_version: str | None = None
    lifecycle: LifecycleState = field(default_factory=LifecycleState.ingested)
    sync: SyncState = field(default_factory=lambda: SyncState(kind="pending"))
    created_at: datetime = field(default_factory=lambda: datetime.utcnow())
    updated_at: datetime = field(default_factory=lambda: datetime.utcnow())

    def __post_init__(self) -> None:
        if self.intent in self.secondary_intents:
            raise ValueError(
                f"primary intent {self.intent.value} must not appear in secondary_intents"
            )
        if len(set(self.secondary_intents)) != len(self.secondary_intents):
            raise ValueError("secondary_intents must not contain duplicates")
        for intent, score in self.intent_applicability.items():
            if not 0.0 <= score <= 1.0:
                raise ValueError(
                    f"applicability for {intent.value} must be in [0, 1], got {score}"
                )

    def swap_primary(self, new_primary: Intent) -> None:
        """사용자가 알림에서 다른 의도를 골랐을 때 primary 를 교체한다.

        - 새 primary 가 기존 secondary 에 있으면 그 위치에서 제거.
        - 기존 primary 는 secondary 의 맨 앞으로 이동 (사용자가 다시 되돌리기 쉽게).
        - applicability 점수는 보존 — Gemini 의 원래 분포는 calibration 자료로 그대로 둔다.
        """
        if new_primary == self.intent:
            return
        new_secondary = list(self.secondary_intents)
        if new_primary in new_secondary:
            new_secondary.remove(new_primary)
        new_secondary.insert(0, self.intent)
        self.intent = new_primary
        self.secondary_intents = tuple(new_secondary)
        self.updated_at = datetime.utcnow()
        self.__post_init__()  # invariant 재검증 — 잘못된 type/중복 진입을 차단.
