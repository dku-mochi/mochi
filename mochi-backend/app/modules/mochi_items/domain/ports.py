from dataclasses import dataclass
from datetime import datetime
from typing import Protocol
from uuid import UUID

from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleState,
    IntentInstance,
    ReviewOption,
)
from app.shared.intent import Intent


class MochiItemRepository(Protocol):
    """Hexagonal outbound port — application layer가 의존하는 추상 저장소.

    모든 read/write 메서드는 ``owner_id`` 를 강제로 받아 cross-tenant 누설을 방지한다.
    """

    async def add(self, *, owner_id: UUID, item: MochiItem) -> None: ...
    async def find_by_id(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None: ...
    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[MochiItem]: ...
    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[MochiItem]: ...
    async def list_in_range(
        self,
        *,
        owner_id: UUID,
        captured_from: datetime | None,
        captured_to: datetime | None,
        intent: Intent | None,
        limit: int,
    ) -> list[MochiItem]:
        """captured_at 구간(``[from, to)``) 내 owner 항목을 captured_at 내림차순으로 조회.

        캘린더 탭의 월간 집계·날짜별 목록의 단일 데이터 소스. ``intent`` 가
        주어지면 그 intent 로 필터(0009 flat intents 이행 후엔 containment 로 바뀌는 단일 지점).
        """
        ...

    async def list_active_todos_with_entities(
        self, *, owner_id: UUID, limit: int
    ) -> list[tuple[MochiItem, tuple[tuple[str, str], ...]]]:
        """미완료(lifecycle=active) todo 와 그 추출 entities ``(kind, value)`` 를 함께 조회.

        마감일은 typed 컬럼이 없고 ``entities(kind='deadline')`` free-text 에만 있어,
        파싱·정렬은 application(`ListUpcomingTodos`)이 담당한다. captured_at 내림차순.
        """
        ...

    async def list_active_actionables_with_entities(
        self, *, owner_id: UUID, limit: int
    ) -> list[tuple[MochiItem, tuple[tuple[str, str], ...]]]:
        """미해결(lifecycle=active) **todo 또는 schedule** instance 가 있는 item + 추출 entities.

        ``list_active_todos_with_entities`` 의 일반화 — "이번주 정리"의 "아직 안 끝났어요" 섹션용.
        마감/일시는 typed 컬럼이 없어 instance payload·entities free-text 를 application 이 파싱한다.
        """
        ...

    async def count(self, *, owner_id: UUID) -> int: ...

    async def list_normalized_categories(self, *, owner_id: UUID, limit: int) -> list[str]:
        """이미 digest 정규화를 거친 distinct category 라벨(최근 정규화순, raw fine 제외).

        주간 정리가 LLM 에 "기존에 자주 쓴 카테고리"로 넘겨, 정규화된 라벨을 다음 주로 이어
        톤앤매너를 연쇄시킨다(아직 정규화 안 된 raw 는 제외).
        """
        ...

    async def bulk_update_category(self, *, owner_id: UUID, categories: dict[UUID, str]) -> None:
        """여러 item 의 ``category`` 를 일괄 갱신(주간 정리 정규화 write). owner-scoped."""
        ...

    async def apply_analysis(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        intent_instances: tuple[IntentInstance, ...],
        needs_review: bool,
        review_options: tuple[ReviewOption, ...],
        summary: str,
        category: str | None,
        importance: int,
        model_version: str,
        entities: tuple[tuple[str, str], ...],
    ) -> None:
        """Agent 분석 결과를 write-back 한다 — 기존 intent_instances·entities 를 delete-reinsert,
        needs_review 갱신, 처리 lifecycle 을 분석 완료(ANALYZED)로 확립.

        review_options 는 mochi_items.review_options JSONB 컬럼에 영속한다 (PR-B 컬럼 승격 —
        헷갈려요 후보를 push payload·GET projection·앱 내 needsReview 버킷 fallback 이 모두 읽는다).
        """
        ...

    async def update_instance_lifecycle(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        instance_id: UUID,
        lifecycle: InstanceLifecycleState,
    ) -> bool:
        """한 intent instance 의 의미 lifecycle 을 전이(완료/완료취소 등).

        owner+mochi_item+instance 3중 scoped UPDATE. instance 가 없거나 다른 owner 면
        ``False`` 반환(→ 404). 전이 합법성(``lifecycle_policy``) 검증은
        application(`UpdateInstanceLifecycle`) 책임 — 포트는 검증된 상태를 그대로 기록한다.
        """
        ...

    async def soft_delete(self, *, owner_id: UUID, mochi_item_id: UUID) -> None:
        """mochi_item 을 soft delete (deleted_at 마킹, 행 보존). owner-scoped — 다른 owner 면 no-op.

        존재/소유 검증은 application(`DeleteMochiItem`)이 find_by_id 로 선행한다(없으면 404).
        """
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


@dataclass(frozen=True, slots=True)
class SignedUpload:
    """클라이언트가 GCS 에 직접 PUT 할 V4 Signed URL + 서버가 부여한 object_key."""

    object_key: str
    upload_url: str
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class SignedDownload:
    """클라이언트가 GCS 에서 직접 GET 할 V4 Signed URL — 앱 재설치 후 이미지 복구용."""

    download_url: str
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

    async def issue_upload_url(self, *, owner_id: UUID, sha256: str, mime_type: str) -> SignedUpload: ...

    async def issue_download_url(self, *, object_key: str) -> SignedDownload:
        """업로드된 객체를 직접 GET 할 V4 Signed URL 발급 (앱 재설치 후 이미지 복구).

        owner-prefix 검증은 호출자(router)가 선행한다 — 포트는 검증된 key 를 그대로 서명한다.
        """
        ...

    async def stat(self, *, object_key: str) -> ObjectStat | None:
        """업로드된 객체의 실제 size/content-type 을 HEAD 로 조회. 객체 없으면 None.

        클라가 신고한 byteSize/mimeType 을 신뢰하지 않고 ingest 시 이걸로 검증한다.
        """
        ...
