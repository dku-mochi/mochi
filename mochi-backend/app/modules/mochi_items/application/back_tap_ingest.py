"""백탭 캡쳐 ingestion use case.

흐름 (worker 단일 분석 경로, 2026-05-30~):
1. Idempotency-Key 로 멱등 재요청을 차단.
2. 클라가 Signed URL 로 GCS 에 올린 이미지의 ``objectKey`` 로 MochiItem(`.screenshot`) 적재.
3. Repository.add → idempotency 기록 → notifier.emit (transactional outbox).
4. 실제 4-Intent 분석은 outbox worker(``AgentOrchestrator``)가 비동기로 수행한다.

동기 분류(Gemini 즉시 호출)는 제거됐다 — 한 캡쳐에 Gemini 가 두 번 호출되던 이중 분석과
DB↔Realm 불일치를 없애기 위함. 후보·confidence 는 worker 가 채우고 iOS 는 폴링으로 반영한다.
"""

from dataclasses import dataclass
from uuid import UUID

from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.ports import (
    MochiItemCreatedNotifier,
    MochiItemRepository,
)


@dataclass(slots=True)
class BackTapIngestCommand:
    owner_id: UUID
    idempotency_key: str
    object_key: str
    mime_type: str
    byte_size: int
    sha256: str
    user_memo: str | None = None


@dataclass(slots=True)
class BackTapIngestResult:
    item: MochiItem
    was_idempotent_replay: bool


class BackTapIngest:
    """백탭 캡쳐를 적재하고 비동기 분석을 트리거하는 use case.

    동기 분류를 하지 않는다 — MochiItem 을 ``.ingested`` 로 적재하고 outbox 로 emit 하면
    worker(``AgentOrchestrator``)가 4-Intent 후보·confidence 를 채운다.
    """

    def __init__(
        self,
        *,
        repository: MochiItemRepository,
        notifier: MochiItemCreatedNotifier,
    ):
        self._repo = repository
        self._notifier = notifier

    async def execute(self, command: BackTapIngestCommand) -> BackTapIngestResult:
        replayed = await self._repo.already_ingested(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
        )
        if replayed is not None:
            return BackTapIngestResult(item=replayed, was_idempotent_replay=True)

        source = IngestSource(
            channel=IngestChannel.SCREENSHOT,
            url=None,
            text=None,
            user_memo=command.user_memo,
            image_refs=(
                ImageRef(
                    sha256=command.sha256,
                    mime_type=command.mime_type,
                    byte_size=command.byte_size,
                    object_key=command.object_key,
                ),
            ),
        )
        item = MochiItem(
            id=source.id,
            source=source,
            lifecycle=LifecycleState(kind=LifecycleStateKind.INGESTED),
        )

        await self._repo.add(owner_id=command.owner_id, item=item)
        await self._repo.remember_idempotency(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
            mochi_item_id=item.id,
        )
        await self._notifier.emit(owner_id=command.owner_id, mochi_item_id=item.id)

        return BackTapIngestResult(item=item, was_idempotent_replay=False)
