import hashlib
from datetime import datetime
from uuid import UUID

from sqlalchemy import ColumnElement, delete, func, select, update
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
from app.modules.mochi_items.domain.value_objects import (
    ArchiveReason,
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
    IntentPayload,
    ReviewOption,
)
from app.modules.mochi_items.infrastructure.orm import (
    EmbeddingRow,
    EntityRow,
    IdempotencyKeyRow,
    IntentInstanceRow,
    MochiItemImageRefRow,
    MochiItemRow,
)
from app.shared.intent import Intent

_PAYLOAD_FIELDS = (
    "title", "date", "time", "end_date", "end_time", "deadline", "person", "topic", "url", "note"
)


def _payload_to_dict(payload: IntentPayload) -> dict[str, str]:
    """채워진 필드만 jsonb 로 저장 (None 은 생략 — 빈 객체 방지)."""
    return {f: value for f in _PAYLOAD_FIELDS if (value := getattr(payload, f)) is not None}


def _dict_to_payload(raw: dict[str, object] | None) -> IntentPayload:
    data = raw or {}
    return IntentPayload(**{f: data.get(f) for f in _PAYLOAD_FIELDS})  # type: ignore[arg-type]


def _row_to_instance(row: IntentInstanceRow) -> IntentInstance:
    archive_reason = ArchiveReason(row.lifecycle_archive_reason) if row.lifecycle_archive_reason else None
    return IntentInstance(
        id=row.id,
        intent_type=Intent(row.intent_type),
        payload=_dict_to_payload(row.payload),
        label=row.label,
        reasoning=row.reasoning or "",
        lifecycle=InstanceLifecycleState(
            kind=InstanceLifecycleKind(row.lifecycle_kind),
            archive_reason=archive_reason,
        ),
    )


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
        intent_instances=tuple(_row_to_instance(i) for i in row.intent_instances),
        needs_review=row.needs_review,
        review_options=tuple(
            ReviewOption(
                intent_type=Intent(r["intent_type"]),
                label=r.get("label"),
                reasoning=r.get("reasoning") or "",
            )
            for r in row.review_options
        ),
        summary=row.summary,
        category=row.category,
        importance=row.importance,
        model_version=row.model_version,
        lifecycle=LifecycleState(
            kind=LifecycleStateKind(row.lifecycle_kind),
            failure_reason=row.lifecycle_failure_reason,
        ),
        sync=SyncState(kind=row.sync_kind, detail=row.sync_detail),  # type: ignore[arg-type]
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _instance_rows(
    owner_id: UUID, item_row: MochiItemRow, instances: tuple[IntentInstance, ...]
) -> list[IntentInstanceRow]:
    return [
        IntentInstanceRow(
            owner_id=owner_id,
            intent_type=inst.intent_type.value,
            payload=_payload_to_dict(inst.payload),
            label=inst.label,
            reasoning=inst.reasoning or None,
            lifecycle_kind=inst.lifecycle.kind.value,
            lifecycle_archive_reason=(
                inst.lifecycle.archive_reason.value if inst.lifecycle.archive_reason else None
            ),
            mochi_item=item_row,
        )
        for inst in instances
    ]


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
            needs_review=item.needs_review,
            summary=item.summary,
            category=item.category,
            importance=item.importance,
            model_version=item.model_version,
            lifecycle_kind=item.lifecycle.kind.value,
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
        for inst_row in _instance_rows(owner_id, row, item.intent_instances):
            row.intent_instances.append(inst_row)
        self._session.add(row)
        await self._session.flush()

    async def find_by_id(self, *, owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        stmt = (
            select(MochiItemRow)
            .where(
                MochiItemRow.id == mochi_item_id,
                MochiItemRow.owner_id == owner_id,
                MochiItemRow.deleted_at.is_(None),
            )
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
            )
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        return _row_to_entity(row) if row else None

    async def list_recent(self, *, owner_id: UUID, limit: int) -> list[MochiItem]:
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, MochiItemRow.deleted_at.is_(None))
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
            )
            .order_by(MochiItemRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def list_by_intent(self, *, owner_id: UUID, intent: Intent, limit: int) -> list[MochiItem]:
        stmt = (
            select(MochiItemRow)
            .where(
                MochiItemRow.owner_id == owner_id,
                self._intent_match(intent),
                MochiItemRow.deleted_at.is_(None),
            )
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
            )
            .order_by(MochiItemRow.created_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    @staticmethod
    def _intent_match(intent: Intent) -> "ColumnElement[bool]":
        """intent 필터의 단일 캡슐화 지점 (1:N — 별도 ``intent_instances`` 테이블 EXISTS).

        해당 type 의 instance 가 하나라도 있으면 매칭. 모든 호출부(list/calendar)가 이 한 곳을
        통해 1:N 의미를 공유한다. (구 대표 컬럼 동등비교에서 0009 빅뱅으로 교체.)
        """
        return (
            select(IntentInstanceRow.id)
            .where(
                IntentInstanceRow.mochi_item_id == MochiItemRow.id,
                IntentInstanceRow.intent_type == intent.value,
            )
            .exists()
        )

    async def list_in_range(
        self,
        *,
        owner_id: UUID,
        captured_from: datetime | None,
        captured_to: datetime | None,
        intent: Intent | None,
        limit: int,
    ) -> list[MochiItem]:
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, MochiItemRow.deleted_at.is_(None))
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
            )
        )
        if captured_from is not None:
            stmt = stmt.where(MochiItemRow.captured_at >= captured_from)
        if captured_to is not None:
            stmt = stmt.where(MochiItemRow.captured_at < captured_to)
        if intent is not None:
            stmt = stmt.where(self._intent_match(intent))
        stmt = stmt.order_by(MochiItemRow.captured_at.desc()).limit(limit)
        rows = (await self._session.scalars(stmt)).all()
        return [_row_to_entity(r) for r in rows]

    async def list_active_todos_with_entities(
        self, *, owner_id: UUID, limit: int
    ) -> list[tuple[MochiItem, tuple[tuple[str, str], ...]]]:
        # 미완료 todo = todo instance 가 active 인 item (instance 단위 lifecycle).
        todo_active = (
            select(IntentInstanceRow.id)
            .where(
                IntentInstanceRow.mochi_item_id == MochiItemRow.id,
                IntentInstanceRow.intent_type == Intent.TODO.value,
                IntentInstanceRow.lifecycle_kind == InstanceLifecycleKind.ACTIVE.value,
            )
            .exists()
        )
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, todo_active, MochiItemRow.deleted_at.is_(None))
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
                selectinload(MochiItemRow.entities),
            )
            .order_by(MochiItemRow.captured_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [(_row_to_entity(r), tuple((e.kind, e.value) for e in r.entities)) for r in rows]

    async def list_active_actionables_with_entities(
        self, *, owner_id: UUID, limit: int
    ) -> list[tuple[MochiItem, tuple[tuple[str, str], ...]]]:
        # 미해결 행동거리 = active 인 todo 또는 schedule instance 가 있는 item.
        # 마감/일시 파싱·정렬은 application(`ListUpcomingActionables`)이 담당(저장은 free-text).
        actionable = (
            select(IntentInstanceRow.id)
            .where(
                IntentInstanceRow.mochi_item_id == MochiItemRow.id,
                IntentInstanceRow.intent_type.in_([Intent.TODO.value, Intent.SCHEDULE.value]),
                IntentInstanceRow.lifecycle_kind == InstanceLifecycleKind.ACTIVE.value,
            )
            .exists()
        )
        stmt = (
            select(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, actionable, MochiItemRow.deleted_at.is_(None))
            .options(
                selectinload(MochiItemRow.image_refs),
                selectinload(MochiItemRow.intent_instances),
                selectinload(MochiItemRow.entities),
            )
            .order_by(MochiItemRow.captured_at.desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [(_row_to_entity(r), tuple((e.kind, e.value) for e in r.entities)) for r in rows]

    async def count(self, *, owner_id: UUID) -> int:
        stmt = (
            select(func.count())
            .select_from(MochiItemRow)
            .where(MochiItemRow.owner_id == owner_id, MochiItemRow.deleted_at.is_(None))
        )
        return int((await self._session.execute(stmt)).scalar_one())

    async def list_normalized_categories(self, *, owner_id: UUID, limit: int) -> list[str]:
        # 이미 digest 정규화(refetch)를 거친 라벨만 — 아직 raw fine(category_normalized_at NULL)은
        # 제외해, 연쇄 톤앤매너 컨텍스트가 정규화된 라벨로만 이어지게 한다.
        # limit 은 row 가 아니라 distinct 라벨 기준 — row 기준이면 한 주 분량(30~40 row)에
        # 윈도우가 소진돼 사실상 "저번주" 컨텍스트로 좁아진다. 라벨별 최근 정규화순.
        stmt = (
            select(MochiItemRow.category)
            .where(
                MochiItemRow.owner_id == owner_id,
                MochiItemRow.deleted_at.is_(None),
                MochiItemRow.category.is_not(None),
                MochiItemRow.category_normalized_at.is_not(None),
            )
            .group_by(MochiItemRow.category)
            .order_by(func.max(MochiItemRow.category_normalized_at).desc())
            .limit(limit)
        )
        rows = (await self._session.scalars(stmt)).all()
        return [category for category in rows if category]

    async def bulk_update_category(self, *, owner_id: UUID, categories: dict[UUID, str]) -> None:
        now = datetime.utcnow()
        for item_id, category in categories.items():
            await self._session.execute(
                update(MochiItemRow)
                .where(MochiItemRow.id == item_id, MochiItemRow.owner_id == owner_id)
                .values(category=category, category_normalized_at=now, updated_at=now)
            )
        await self._session.flush()

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
        stmt = select(MochiItemRow).where(MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id)
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return

        row.summary = summary
        row.category = category
        row.importance = importance
        row.needs_review = needs_review
        # 미확정 후보 영속 — JSONB 컬럼 in-place 덮어쓰기 (재분석 멱등, delete-reinsert 불필요).
        row.review_options = [
            {"intent_type": r.intent_type.value, "label": r.label, "reasoning": r.reasoning}
            for r in review_options
        ]
        row.model_version = model_version
        # 처리상태 → 분석 완료(analyzed). 처리상태는 단일 선형이라 정책 검증 없이 확립.
        row.lifecycle_kind = LifecycleStateKind.ANALYZED.value
        row.updated_at = datetime.utcnow()

        # intent_instances 재적재 — 재분석 시 전량 delete-reinsert (멱등). 사용자 완료상태도
        # 함께 폐기되나 prod 전까지 실데이터 없어 안전(handoff §4 — 보존은 후속 sprint).
        await self._session.execute(
            delete(IntentInstanceRow).where(IntentInstanceRow.mochi_item_id == mochi_item_id)
        )
        for inst_row in _instance_rows(owner_id, row, intent_instances):
            self._session.add(inst_row)

        # entities 재적재 — 동일 멱등 패턴.
        await self._session.execute(delete(EntityRow).where(EntityRow.mochi_item_id == mochi_item_id))
        for kind, value in entities:
            # mochi_item=row 를 함께 줘야 한다 — MappedAsDataclass + relationship(default=None) 조합에서
            # FK 만 주면 relationship 의 None 이 flush 시 mochi_item_id 를 NULL 로 덮어쓴다(NotNullViolation).
            self._session.add(
                EntityRow(
                    mochi_item_id=mochi_item_id,
                    kind=kind[:16],
                    value=value[:512],
                    mochi_item=row,
                )
            )
        await self._session.flush()

    async def replace_embedding(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        chunk_text: str,
        embedding: list[float],
        model_version: str,
    ) -> None:
        stmt = select(MochiItemRow).where(
            MochiItemRow.id == mochi_item_id,
            MochiItemRow.owner_id == owner_id,
            # soft-delete 직후 재색인되는 TOCTOU 창 차단 — 지워진 기록은 색인하지 않는다 (리뷰 P2).
            MochiItemRow.deleted_at.is_(None),
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return
        # delete-reinsert — 재분석·backfill 멱등 (apply_analysis 의 instances/entities 와 동일 패턴).
        await self._session.execute(
            delete(EmbeddingRow).where(EmbeddingRow.mochi_item_id == mochi_item_id)
        )
        self._session.add(
            EmbeddingRow(
                mochi_item_id=mochi_item_id,
                chunk_text=chunk_text,
                embedding=embedding,
                model_version=model_version,
                # FK 만 주면 relationship(default=None)이 flush 시 NULL 로 덮어쓴다 — EntityRow 와 동일.
                mochi_item=row,
            )
        )
        await self._session.flush()

    async def update_instance_lifecycle(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        instance_id: UUID,
        lifecycle: InstanceLifecycleState,
    ) -> bool:
        # owner+item+instance 3중 scoped — cross-tenant/IDOR 차단(다른 owner 의 instance 면 None→False).
        stmt = select(IntentInstanceRow).where(
            IntentInstanceRow.id == instance_id,
            IntentInstanceRow.mochi_item_id == mochi_item_id,
            IntentInstanceRow.owner_id == owner_id,
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return False
        row.lifecycle_kind = lifecycle.kind.value
        row.lifecycle_archive_reason = lifecycle.archive_reason.value if lifecycle.archive_reason else None
        await self._session.flush()
        return True

    async def update_content(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        text: str | None,
        user_memo: str | None,
        summary: str | None,
    ) -> bool:
        values: dict[str, object] = {
            key: value
            for key, value in {"text": text, "user_memo": user_memo, "summary": summary}.items()
            if value is not None
        }
        if not values:
            return True  # 변경할 필드 없음 — 멱등 no-op
        values["updated_at"] = datetime.utcnow()
        result = await self._session.execute(
            update(MochiItemRow)
            .where(
                MochiItemRow.id == mochi_item_id,
                MochiItemRow.owner_id == owner_id,
                MochiItemRow.deleted_at.is_(None),
            )
            .values(**values)
        )
        await self._session.flush()
        return bool(getattr(result, "rowcount", 0))

    async def update_instance_fields(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        instance_id: UUID,
        payload: dict[str, str] | None,
        label: str | None,
    ) -> bool:
        # owner+item+instance 3중 scoped — update_instance_lifecycle 과 동일 패턴.
        stmt = select(IntentInstanceRow).where(
            IntentInstanceRow.id == instance_id,
            IntentInstanceRow.mochi_item_id == mochi_item_id,
            IntentInstanceRow.owner_id == owner_id,
        )
        row = (await self._session.scalars(stmt)).one_or_none()
        if row is None:
            return False
        if payload is not None:
            row.payload = payload
        if label is not None:
            row.label = label
        row.updated_at = datetime.utcnow()
        await self._session.flush()
        return True

    async def soft_delete(self, *, owner_id: UUID, mochi_item_id: UUID) -> None:
        """행을 지우지 않고 deleted_at 마킹(soft delete). 모든 조회가 deleted_at IS NULL 로 가린다.

        owner-scoped — 다른 owner 의 항목은 UPDATE 대상에서 빠진다(no-op). 존재/소유 검증은
        application(`DeleteMochiItem`)이 find_by_id 로 선행해 없는 항목은 404 로 끊는다.
        """
        await self._session.execute(
            update(MochiItemRow)
            .where(MochiItemRow.id == mochi_item_id, MochiItemRow.owner_id == owner_id)
            .values(deleted_at=func.now())
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
