"""백탭 캡쳐 ingestion use case.

흐름 — `_workspace/2026-05-25-intent-classification-bench.md` 의 권장 spec:
1. Idempotency-Key 로 멱등 재요청을 차단 (이미 적재된 MochiItem 이 있으면 그대로 반환,
   재호출 시 Gemini 비용/latency 발생 안 함).
2. 이미지를 ``IntentClassifier`` 로 분류 → 후보 3개 + applicability.
3. ``MochiItem.from_classification`` 으로 primary/secondary/applicability_map 도출.
4. Repository.add → idempotency 기록 → notifier.emit (transactional outbox).
"""

from dataclasses import dataclass
from uuid import UUID

from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    MochiItem,
)
from app.modules.mochi_items.domain.ports import (
    IntentClassifier,
    MochiItemCreatedNotifier,
    MochiItemRepository,
)
from app.modules.mochi_items.domain.value_objects import IntentClassification


@dataclass(slots=True)
class BackTapIngestCommand:
    owner_id: UUID
    idempotency_key: str
    image: bytes
    mime_type: str
    byte_size: int
    sha256: str
    user_memo: str | None = None


@dataclass(slots=True)
class BackTapIngestResult:
    item: MochiItem
    candidates: tuple[IntentClassification, ...]
    was_idempotent_replay: bool


class BackTapIngest:
    """백탭 캡쳐를 동기적으로 분류하고 저장하는 use case.

    분류 latency (~2.8s p50) 는 호출자가 알림 UX 의 일부로 흡수한다.
    분류 실패 시 ``IntentClassifier`` 의 예외가 그대로 전파되어 라우터가
    표준 에러 envelope 으로 변환한다.
    """

    def __init__(
        self,
        *,
        repository: MochiItemRepository,
        notifier: MochiItemCreatedNotifier,
        classifier: IntentClassifier,
    ):
        self._repo = repository
        self._notifier = notifier
        self._classifier = classifier

    async def execute(self, command: BackTapIngestCommand) -> BackTapIngestResult:
        replayed = await self._repo.already_ingested(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
        )
        if replayed is not None:
            return BackTapIngestResult(
                item=replayed,
                candidates=(),
                was_idempotent_replay=True,
            )

        classification = await self._classifier.classify(
            image=command.image,
            mime=command.mime_type,
        )

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
                    object_key=None,
                ),
            ),
        )
        item = MochiItem.from_classification(
            source=source,
            classification=classification,
        )

        await self._repo.add(owner_id=command.owner_id, item=item)
        await self._repo.remember_idempotency(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
            mochi_item_id=item.id,
        )
        await self._notifier.emit(owner_id=command.owner_id, mochi_item_id=item.id)

        return BackTapIngestResult(
            item=item,
            candidates=classification.candidates,
            was_idempotent_replay=False,
        )
