import hashlib
from datetime import datetime
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.modules.mochi_items.domain.entities import (
    Capture,
    CaptureChannel,
    CaptureSource,
    ImageRef,
    LifecycleState,
    LifecycleStateKind,
    SyncState,
)
from app.modules.mochi_items.domain.ports import CaptureRepository
from app.modules.mochi_items.infrastructure.orm import (
    CaptureImageRefRow,
    CaptureRow,
    IdempotencyKeyRow,
)
from app.shared.intent import Intent


def _row_to_entity(row: CaptureRow) -> Capture:
    image_refs = tuple(
        ImageRef(
            sha256=img.sha256,
            mime_type=img.mime_type,
            byte_size=img.byte_size,
            object_key=img.object_key,
        )
        for img in row.image_refs
    )
    source = CaptureSource(
        id=row.id,
        channel=CaptureChannel(row.channel),
        url=row.url,
        text=row.text,
        user_memo=row.user_memo,
        image_refs=image_refs,
        captured_at=row.captured_at,
    )
    return Capture(
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


class PostgresCaptureRepository(CaptureRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def add(self, *, owner_id: UUID, capture: Capture) -> None:
        row = CaptureRow(
            owner_id=owner_id,
            channel=capture.source.channel.value,
            url=capture.source.url,
            text=capture.source.text,
            user_memo=capture.source.user_memo,
            intent=capture.intent.value,
            secondary_intents=[s.value for s in capture.secondary_intents],
            intent_applicability={k.value: v for k, v in capture.intent_applicability.items()},
            summary=capture.summary,
            importance=capture.importance,
            confidence=capture.confidence,
            model_version=capture.model_version,
            lifecycle_kind=capture.lifecycle.kind.value,
            lifecycle_archive_reason=capture.lifecycle.archive_reason.value if capture.lifecycle.archive_reason else None,
            lifecycle_failure_reason=capture.lifecycle.failure_reason,
            sync_kind=capture.sync.kind,
            sync_detail=capture.sync.detail,
            captured_at=capture.source.captured_at,
            created_at=capture.created_at,
            updated_at=capture.updated_at,
        )
        row.id = capture.id  # type: ignore[assignment]
        for img in capture.source.image_refs:
            row.image_refs.append(
                CaptureImageRefRow(
                    sha256=img.sha256,
                    mime_type=img.mime_type,
                    byte_size=img.byte_size,
                    object_key=img.object_key,
                )
            )
        self._session.add(row)
        await self._session.flush()

    async def find_by_id(self, *, owner_id: UUID, capture_id: UUID) -> Capture | None:
        stmt = (
            select(CaptureRow)
            .where(CaptureRow.id == capture_id, CaptureRow.owner_id == owner_id)
            .options(selectinload(CaptureRow.image_refs))
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        return _row_to_entity(row) if row else None

    async def update_lifecycle(
        self,
        *,
        owner_id: UUID,
        capture_id: UUID,
        new_state: LifecycleState,
    ) -> None:
        from app.core.error_envelope import DomainError
        from app.modules.intents.domain.lifecycle_policy import is_allowed

        stmt = select(CaptureRow).where(CaptureRow.id == capture_id, CaptureRow.owner_id == owner_id)
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return

        current = LifecycleState(kind=LifecycleStateKind(row.lifecycle_kind))
        intent = Intent(row.intent)
        if not is_allowed(intent, current, new_state):
            raise DomainError(
                f"Illegal lifecycle transition for {intent.value}: "
                f"{current.kind.value} → {new_state.kind.value} (reason={new_state.archive_reason})",
                code="capture.illegal_lifecycle_transition",
            )

        row.lifecycle_kind = new_state.kind.value
        row.lifecycle_archive_reason = new_state.archive_reason.value if new_state.archive_reason else None
        row.lifecycle_failure_reason = new_state.failure_reason
        await self._session.flush()

    async def update_primary_intent(
        self,
        *,
        owner_id: UUID,
        capture_id: UUID,
        new_primary: Intent,
        new_secondary: tuple[Intent, ...],
    ) -> None:
        stmt = select(CaptureRow).where(
            CaptureRow.id == capture_id, CaptureRow.owner_id == owner_id
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return
        row.intent = new_primary.value
        row.secondary_intents = [s.value for s in new_secondary]
        row.updated_at = datetime.utcnow()
        await self._session.flush()

    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[Capture]:
        stmt = (
            select(CaptureRow)
            .where(CaptureRow.owner_id == owner_id)
            .options(selectinload(CaptureRow.image_refs))
            .order_by(CaptureRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[Capture]:
        stmt = (
            select(CaptureRow)
            .where(CaptureRow.owner_id == owner_id, CaptureRow.intent == intent.value)
            .options(selectinload(CaptureRow.image_refs))
            .order_by(CaptureRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def already_ingested(self, *, owner_id: UUID, idempotency_key: str) -> Capture | None:
        scoped_key = self._scope_idempotency_key(owner_id=owner_id, raw_key=idempotency_key)
        row = await self._session.get(IdempotencyKeyRow, scoped_key)
        if row is None:
            return None
        return await self.find_by_id(owner_id=owner_id, capture_id=row.capture_id)

    async def remember_idempotency(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        capture_id: UUID,
    ) -> None:
        scoped_key = self._scope_idempotency_key(owner_id=owner_id, raw_key=idempotency_key)
        self._session.add(IdempotencyKeyRow(key=scoped_key, capture_id=capture_id))
        await self._session.flush()

    @staticmethod
    def _scope_idempotency_key(*, owner_id: UUID, raw_key: str) -> str:
        """오너 + 라우트 + raw key 의 sha256 — 길이 안정성과 충돌 회피를 동시에 보장."""
        digest = hashlib.sha256(f"capture:{owner_id}:{raw_key}".encode()).hexdigest()
        return digest  # 64-char hex, fits in varchar(128)
