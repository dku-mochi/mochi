from dataclasses import dataclass, field
from uuid import UUID

from app.modules.captures.domain.entities import (
    Capture,
    CaptureChannel,
    CaptureSource,
    ImageRef,
    LifecycleState,
    LifecycleStateKind,
)
from app.modules.captures.domain.ports import CaptureCreatedNotifier, CaptureRepository


@dataclass(slots=True)
class IngestCaptureCommand:
    owner_id: UUID
    channel: CaptureChannel
    url: str | None
    text: str | None
    user_memo: str | None
    idempotency_key: str
    image_refs: tuple[ImageRef, ...] = field(default_factory=tuple)


@dataclass(slots=True)
class IngestCaptureResult:
    capture: Capture
    was_idempotent_replay: bool


class IngestCapture:
    """캡처 ingestion 유스케이스 — agent loop 트리거 전까지의 책임만 진다.

    부수 효과:
    - Idempotency key는 owner 별로 격리되어, 다른 사용자의 같은 key와 충돌하지 않는다
    - 첨부 이미지 메타데이터는 같은 트랜잭션에서 capture_image_refs 테이블에 함께 적재된다
    - 생성된 캡처는 즉시 notifier로 emit되어 agent worker가 분석을 시작한다
    """

    def __init__(self, repository: CaptureRepository, notifier: CaptureCreatedNotifier):
        self._repo = repository
        self._notifier = notifier

    async def execute(self, command: IngestCaptureCommand) -> IngestCaptureResult:
        replayed = await self._repo.already_ingested(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
        )
        if replayed is not None:
            return IngestCaptureResult(capture=replayed, was_idempotent_replay=True)

        source = CaptureSource(
            channel=command.channel,
            url=command.url,
            text=command.text,
            user_memo=command.user_memo,
            image_refs=command.image_refs,
        )
        capture = Capture(
            id=source.id,
            source=source,
            lifecycle=LifecycleState(kind=LifecycleStateKind.INGESTED),
        )

        await self._repo.add(owner_id=command.owner_id, capture=capture)
        await self._repo.remember_idempotency(
            owner_id=command.owner_id,
            idempotency_key=command.idempotency_key,
            capture_id=capture.id,
        )
        await self._notifier.emit(owner_id=command.owner_id, capture_id=capture.id)

        return IngestCaptureResult(capture=capture, was_idempotent_replay=False)
