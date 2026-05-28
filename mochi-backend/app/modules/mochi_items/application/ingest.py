from dataclasses import dataclass, field
from uuid import UUID

from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.ports import MochiItemCreatedNotifier, MochiItemRepository


@dataclass(slots=True)
class IngestCommand:
    owner_id: UUID
    channel: IngestChannel
    url: str | None
    text: str | None
    user_memo: str | None
    idempotency_key: str
    image_refs: tuple[ImageRef, ...] = field(default_factory=tuple)


@dataclass(slots=True)
class IngestResult:
    item: MochiItem
    was_idempotent_replay: bool


class Ingest:
    """MochiItem ingestion 유스케이스 — agent loop 트리거 전까지의 책임만 진다.

    부수 효과:
    - Idempotency key는 owner 별로 격리되어, 다른 사용자의 같은 key와 충돌하지 않는다
    - 첨부 이미지 메타데이터는 같은 트랜잭션에서 mochi_item_image_refs 테이블에 함께 적재된다
    - 생성된 MochiItem은 즉시 notifier로 emit되어 agent worker가 분석을 시작한다
    """

    def __init__(self, repository: MochiItemRepository, notifier: MochiItemCreatedNotifier):
        self._repo = repository
        self._notifier = notifier

    async def execute(self, command: IngestCommand) -> IngestResult:
        replayed = await self._repo.already_ingested(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
        )
        if replayed is not None:
            return IngestResult(item=replayed, was_idempotent_replay=True)

        source = IngestSource(
            channel=command.channel,
            url=command.url,
            text=command.text,
            user_memo=command.user_memo,
            image_refs=command.image_refs,
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

        return IngestResult(item=item, was_idempotent_replay=False)
