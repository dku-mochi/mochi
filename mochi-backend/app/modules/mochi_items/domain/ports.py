from dataclasses import dataclass
from datetime import datetime
from typing import Protocol
from uuid import UUID

from app.modules.mochi_items.domain.entities import LifecycleState, MochiItem
from app.modules.mochi_items.domain.value_objects import IntentClassificationResult
from app.shared.intent import Intent


class MochiItemRepository(Protocol):
    """Hexagonal outbound port — application layer가 의존하는 추상 저장소.

    모든 read/write 메서드는 ``owner_id`` 를 강제로 받아 cross-tenant 누설을 방지한다.
    """

    async def add(self, *, owner_id: UUID, item: MochiItem) -> None: ...
    async def find_by_id(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None: ...
    async def update_lifecycle(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        new_state: LifecycleState,
    ) -> None: ...
    async def update_primary_intent(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        new_primary: Intent,
        new_secondary: tuple[Intent, ...],
    ) -> None: ...
    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[MochiItem]: ...
    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[MochiItem]: ...
    async def count(self, *, owner_id: UUID) -> int: ...
    async def apply_analysis(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        intent: Intent,
        secondary_intents: tuple[Intent, ...],
        intent_applicability: dict[Intent, float],
        summary: str,
        importance: int,
        confidence: float,
        model_version: str,
        entities: tuple[tuple[str, str], ...],
    ) -> None:
        """Agent 분석 결과를 write-back 한다 — 분석 필드 갱신 + entities 재적재 +
        lifecycle 를 분석 완료 상태(ACTIVE)로 확립."""
        ...
    async def already_ingested(self, *, owner_id: UUID, idempotency_key: str) -> MochiItem | None: ...
    async def remember_idempotency(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        mochi_item_id: UUID,
    ) -> None: ...


class MochiItemCreatedNotifier(Protocol):
    """MochiItem 생성 후 비동기 워커가 듣는 outbound port — 이벤트 디스패치."""

    async def emit(self, *, owner_id: UUID, mochi_item_id: UUID) -> None: ...


class IntentClassifier(Protocol):
    """백탭 캡쳐 이미지를 LLM 으로 분류해 의도 후보를 도출하는 outbound port.

    구현체는 ``image_uri`` (gs:// URI) 와 ``mime`` (image/jpeg | image/png) 를 입력으로 받고,
    후보 3개를 담은 ``IntentClassificationResult`` 를 반환한다. 클라이언트가 GCS 에 직접
    업로드하므로 서버는 bytes 를 들지 않고, Gemini 가 gs:// 를 직접 읽는다.
    """

    async def classify(self, *, image_uri: str, mime: str) -> IntentClassificationResult: ...


@dataclass(frozen=True, slots=True)
class SignedUpload:
    """클라이언트가 GCS 에 직접 PUT 할 V4 Signed URL + 서버가 부여한 object_key."""

    object_key: str
    upload_url: str
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class ObjectStat:
    """업로드된 객체의 실제 metadata (서버 검증용 — 클라 self-report 가 아님)."""

    size: int
    content_type: str | None


class CaptureImageStorage(Protocol):
    """캡처 이미지용 V4 Signed PUT URL 발급 + 업로드된 객체 검증 outbound port.

    클라이언트가 이 URL 로 GCS 에 직접 업로드하므로 서버는 이미지 bytes 를 만지지 않는다.
    동일 ``sha256`` → 동일 object_key (content-addressed). 이후 agent 는
    ``gs://{bucket}/{object_key}`` 로 Gemini 에 직접 넘긴다.
    """

    async def issue_upload_url(
        self, *, owner_id: UUID, sha256: str, mime_type: str
    ) -> SignedUpload: ...

    async def stat(self, *, object_key: str) -> ObjectStat | None:
        """업로드된 객체의 실제 size/content-type 을 HEAD 로 조회. 객체 없으면 None.

        클라가 신고한 byteSize/mimeType 을 신뢰하지 않고 ingest 시 이걸로 검증한다.
        """
        ...
