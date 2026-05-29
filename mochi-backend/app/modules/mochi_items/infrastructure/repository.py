import hashlib
from datetime import datetime
from uuid import UUID

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
    SyncState,
)
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.infrastructure.orm import (
    EntityRow,
    IdempotencyKeyRow,
    MochiItemImageRefRow,
    MochiItemRow,
)
from app.shared.intent import Intent


def _row_to_entity(row: MochiItemRow) -> MochiItem:
    image_refs = tuple(
        ImageRef(
            sha256=img.sha256,
            mime_type=img.mime_type,
            byte_size=img.byte_size,
            object_key=img.object_key,
        )
        for img in row.image_refs
    )
    source = IngestSource(
        id=row.id,
        channel=IngestChannel(row.channel),
        url=row.url,
        text=row.text,
        user_memo=row.user_memo,
        image_refs=image_refs,
        captured_at=row.captured_at,
    )
    return MochiItem(
        id=row.id,
        source=source,
        intent=Intent(row.intent),
        secondary_intents=tuple(Intent(s) for s in row.secondary_intents),
        intent_applicability={Intent(k): v for k, v in row.intent_applicability.items()},
        summary=row.summary,
        importance=row.importance,
        confidence=row.confidence,
        model_version=row.model_version,
        lifecycle=LifecycleState(kind=LifecycleStateKind(row.lifecycle_kind)),
        sync=SyncState(kind=row.sync_kind, detail=row.sync_detail),  # type: ignore[arg-type]
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


class PostgresMochiItemRepository(MochiItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def add(self, *, owner_id: UUID, item: MochiItem) -> None:
        row = MochiItemRow(
            owner_id=owner_id,
            channel=item.source.channel.value,
            url=item.source.url,
            text=item.source.text,
            user_memo=item.source.user_memo,
            intent=item.intent.value,
            secondary_intents=[s.value for s in item.secondary_intents],
            intent_applicability={k.value: v for k, v in item.intent_applicability.items()},
            summary=item.summary,
            importance=item.importance,
            confidence=item.confidence,
            model_version=item.model_version,
            lifecycle_kind=item.lifecycle.kind.value,
            lifecycle_archive_reason=item.lifecycle.archive_reason.value if item.lifecycle.archive_reason else None,
            lifecycle_failure_reason=item.lifecycle.failure_reason,
            sync_kind=item.sync.kind,
            sync_detail=item.sync.detail,
            captured_at=item.source.captured_at,
            created_at=item.created_at,
            updated_at=item.updated_at,
        )
        row.id = item.id
        for img in item.source.image_refs:
            row.image_refs.append(
                MochiItemImageRefRow(
                    sha256=img.sha256,
                    mime_type=img.mime_type,
                    byte_size=img.byte_size,
                    object_key=img.object_key,
                )
            )
        self._session.add(row)
        await self._session.flush()

    async def find_by_id(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id)
            .options(selectinload(MochiItemRow.image_refs))
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        return _row_to_entity(row) if row else None

    async def update_lifecycle(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        new_state: LifecycleState,
    ) -> None:
        from app.core.error_envelope import DomainError
        from app.modules.intents.domain.lifecycle_policy import is_allowed

        stmt = select(MochiItemRow).where(MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id)
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return

        current = LifecycleState(kind=LifecycleStateKind(row.lifecycle_kind))
        intent = Intent(row.intent)
        if not is_allowed(intent, current, new_state):
            raise DomainError(
                f"Illegal lifecycle transition for {intent.value}: "
                f"{current.kind.value} → {new_state.kind.value} (reason={new_state.archive_reason})",
                code="mochi_item.illegal_lifecycle_transition",
            )

        row.lifecycle_kind = new_state.kind.value
        row.lifecycle_archive_reason = new_state.archive_reason.value if new_state.archive_reason else None
        row.lifecycle_failure_reason = new_state.failure_reason
        await self._session.flush()

    async def update_primary_intent(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        new_primary: Intent,
        new_secondary: tuple[Intent, ...],
    ) -> None:
        stmt = select(MochiItemRow).where(
            MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return
        row.intent = new_primary.value
        row.secondary_intents = [s.value for s in new_secondary]
        row.updated_at = datetime.utcnow()
        await self._session.flush()

    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[MochiItem]:
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id)
            .options(selectinload(MochiItemRow.image_refs))
            .order_by(MochiItemRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[MochiItem]:
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, MochiItemRow.intent == intent.value)
            .options(selectinload(MochiItemRow.image_refs))
            .order_by(MochiItemRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def count(self, *, owner_id: UUID) -> int:
        stmt = select(func.count()).select_from(MochiItemRow).where(MochiItemRow.owner_id == owner_id)
        return int((await self._session.execute(stmt)).scalar_one())

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
        stmt = select(MochiItemRow).where(
            MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return

        row.intent = intent.value
        row.secondary_intents = [s.value for s in secondary_intents]
        row.intent_applicability = {k.value: v for k, v in intent_applicability.items()}
        row.summary = summary
        row.importance = importance
        row.confidence = confidence
        row.model_version = model_version
        row.updated_at = datetime.utcnow()

        # 분석 완료 → lifecycle 확립. 정책(INGESTED→ANALYZING→ACTIVE)의 2단계를
        # is_allowed 로 검증한다 (직접 INGESTED→ACTIVE 쌍은 정책상 불허이므로 우회 금지).
        from app.modules.intents.domain.lifecycle_policy import is_allowed

        current = LifecycleState(kind=LifecycleStateKind(row.lifecycle_kind))
        analyzing = LifecycleState(kind=LifecycleStateKind.ANALYZING)
        active = LifecycleState(kind=LifecycleStateKind.ACTIVE)
        if current.kind is LifecycleStateKind.INGESTED and is_allowed(intent, current, analyzing):
            current = analyzing
        if current.kind is LifecycleStateKind.ANALYZING and is_allowed(intent, current, active):
            row.lifecycle_kind = LifecycleStateKind.ACTIVE.value

        # entities 재적재 — 재분석 시 멱등.
        await self._session.execute(
            delete(EntityRow).where(EntityRow.mochi_item_id == mochi_item_id)
        )
        for kind, value in entities:
            self._session.add(
                EntityRow(mochi_item_id=mochi_item_id, kind=kind[:16], value=value[:512])
            )
        await self._session.flush()

    async def already_ingested(self, *, owner_id: UUID, idempotency_key: str) -> MochiItem | None:
        scoped_key = self._scope_idempotency_key(owner_id=owner_id, raw_key=idempotency_key)
        row = await self._session.get(IdempotencyKeyRow, scoped_key)
        if row is None:
            return None
        return await self.find_by_id(owner_id=owner_id, mochi_item_id=row.mochi_item_id)

    async def remember_idempotency(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        mochi_item_id: UUID,
    ) -> None:
        scoped_key = self._scope_idempotency_key(owner_id=owner_id, raw_key=idempotency_key)
        self._session.add(IdempotencyKeyRow(key=scoped_key, mochi_item_id=mochi_item_id))
        await self._session.flush()

    @staticmethod
    def _scope_idempotency_key(*, owner_id: UUID, raw_key: str) -> str:
        """오너 + 라우트 + raw key 의 sha256 — 길이 안정성과 충돌 회피를 동시에 보장."""
        digest = hashlib.sha256(f"mochi_item:{owner_id}:{raw_key}".encode()).hexdigest()
        return digest  # 64-char hex, fits in varchar(128)
