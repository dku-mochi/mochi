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
from app.modules.mochi_items.domain.value_objects import IntentInstance


@dataclass(slots=True)
class IngestCommand:
    owner_id: UUID
    channel: IngestChannel
    url: str | None
    text: str | None
    user_memo: str | None
    idempotency_key: str
    image_refs: tuple[ImageRef, ...] = field(default_factory=tuple)
    # 채팅 proposal 확정으로 사용자가 직접 확정한 instance — 있으면 분석 파이프라인을 생략한다
    # (DOMAIN_DESIGN §5.2 예외: "사용자 확정 = 분석보다 상위 신뢰". journal 2026-06-10 M2).
    confirmed_instances: tuple[IntentInstance, ...] = ()
    # 확정 instance 와 함께 propose-시점에 도출된 item 메타(분류·요약). instance 는 그대로 두고
    # category/summary 만 채운다 — 월간정리 "그 외"·검색 빈약 방지(§5.2 는 instance 재분석만 생략).
    category: str | None = None
    summary: str | None = None
    # 분석 전용 ephemeral OCR(iOS Vision OCR). 일반 ingest(분석 파이프라인)에서만 실린다 —
    # confirmed_instances 경로는 즉시 analyzed 라 삭제 훅을 안 거치므로 execute() 가 OCR 을 None 으로
    # 비운다(ephemeral 불변식 코드 강제). 채팅 proposal 은 스크린샷이 없어 실무상 OCR=None 이기도 하다.
    analysis_ocr_text: str | None = None


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
            # confirmed_instances 경로는 즉시 lifecycle=ANALYZED 로 만들어 outbox 를 안 태운다 →
            # apply_analysis 삭제 훅이 영영 호출되지 않는다. ephemeral 불변식("analyzed 면 OCR NULL")을
            # 주석이 아니라 코드로 강제: 분석 파이프라인을 타는 경우에만 OCR 을 싣는다(아니면 영구 잔류, P1).
            analysis_ocr_text=None if command.confirmed_instances else command.analysis_ocr_text,
            image_refs=command.image_refs,
        )
        if command.confirmed_instances:
            # §5.2 예외 — 사용자 확정 proposal: instance 즉시 active 생성 + 분석 완료 상태,
            # outbox 미적재(재분석이 확정 내용을 덮으면 "확정했는데 모찌가 되묻는" UX 파탄).
            item = MochiItem(
                id=source.id,
                source=source,
                intent_instances=command.confirmed_instances,
                category=command.category,
                summary=command.summary,
                lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
            )
        else:
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
        if not command.confirmed_instances:
            await self._notifier.emit(owner_id=command.owner_id, mochi_item_id=item.id)

        return IngestResult(item=item, was_idempotent_replay=False)
