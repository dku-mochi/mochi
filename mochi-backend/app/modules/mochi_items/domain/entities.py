from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID, uuid4

from app.modules.mochi_items.domain.value_objects import IntentInstance, ReviewOption
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
    # 채팅 proposal 확정으로 생성된 기록 (propose_create_memo/schedule — journal 2026-06-10).
    CHAT = "chat"
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


# ---------- Lifecycle (처리상태 — item 단위 분석 파이프라인) ----------
# 의미 lifecycle(완료/만료/decay)은 intent instance 단위로 이동했다(2026-06-04 빅뱅).
# 여기 LifecycleState 는 "분석 파이프라인이 어디까지 진행됐나"만 표현한다. archive_reason 없음.


class LifecycleStateKind(StrEnum):
    INGESTED = "ingested"
    ANALYZING = "analyzing"
    ANALYZED = "analyzed"  # 구 active — 분석 완료, instance 적재됨. iOS 폴링 컷오버 신호.
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class LifecycleState:
    kind: LifecycleStateKind
    failure_reason: str | None = None

    @classmethod
    def ingested(cls) -> "LifecycleState":
        return cls(kind=LifecycleStateKind.INGESTED)


# ---------- Sync ----------


@dataclass(frozen=True, slots=True)
class SyncState:
    kind: Literal["pending", "uploaded", "calendar_synced", "reminder_synced", "failed"]
    detail: str | None = None


# ---------- MochiItem (aggregate root) ----------


@dataclass(slots=True)
class MochiItem:
    """MochiItem aggregate root — URL·이미지·링크를 통합한 모찌 항목.

    Intent 표현 (2026-06-04 빅뱅 — lab FINDINGS):
    - ``intent_instances``: LLM 이 펼친 의도들. 저장된 instance 는 곧 active. **위계 없음** —
      같은 type 다중 허용. 점수(applicability/confidence)·대표(primary)·threshold 폐기.
      worker 가 비동기로 채운다(별도 ``intent_instances`` 테이블).
    - ``needs_review``: LLM holistic 판단 — 모찌가 분류를 확신 못 해 사용자에게 물을지.
    - ``review_options``: needs_review 일 때 제시할 미확정 후보 (mochi_items JSONB 영속 — PR-B).
    - ``lifecycle``: **처리상태**(ingested/analyzing/analyzed/failed). 의미 lifecycle 은 각
      ``IntentInstance.lifecycle`` 에 있다(가드레일 1 — lifecycle 의미 2분할).
    """

    id: UUID
    source: IngestSource
    intent_instances: tuple[IntentInstance, ...] = ()
    needs_review: bool = False
    review_options: tuple[ReviewOption, ...] = ()
    summary: str | None = None
    category: str | None = None
    shopping_product_query: str | None = None
    importance: int = 3
    model_version: str | None = None
    lifecycle: LifecycleState = field(default_factory=LifecycleState.ingested)
    sync: SyncState = field(default_factory=lambda: SyncState(kind="pending"))
    created_at: datetime = field(default_factory=lambda: datetime.utcnow())
    updated_at: datetime = field(default_factory=lambda: datetime.utcnow())

    @property
    def intent_types(self) -> tuple[Intent, ...]:
        """이 item 이 가진 distinct intent type (출현 순서 보존). UI 칩·프로필 window 용."""
        seen: dict[Intent, None] = {}
        for inst in self.intent_instances:
            seen.setdefault(inst.intent_type, None)
        return tuple(seen)

    @property
    def display_title(self) -> str | None:
        """프로필/분석 컨텍스트용 대표 제목. iOS 대표 우선순위와 같은 순서를 쓴다."""
        priority = (Intent.SCHEDULE, Intent.TODO, Intent.KNOWLEDGE, Intent.MEMO)
        for intent in priority:
            for inst in self.intent_instances:
                title = inst.payload.title
                if inst.intent_type == intent and title:
                    return title
        for inst in self.intent_instances:
            if inst.payload.title:
                return inst.payload.title
        return None
