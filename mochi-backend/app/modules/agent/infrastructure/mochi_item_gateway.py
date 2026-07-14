"""`MochiItemGateway` 구현체 — agent 가 mochi_items 모듈에 접근하는 유일한 통로.

모듈 경계: ``mochi_items.application`` (factory + 조회 use case) 와 ``mochi_items.domain``
(repository Protocol) 만 import 한다. infrastructure 직접 reach 없음.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.modules.agent.domain.analysis import AnalysisResult
from app.modules.agent.domain.gateway import AnalysisInput, MochiItemGateway
from app.modules.agent.domain.profile import ProfileWindowItem
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)


class MochiItemGatewayAdapter(MochiItemGateway):
    def __init__(self, session: AsyncSession):
        self._repo = make_mochi_item_repository(session)

    async def load_source(self, *, owner_id: UUID, mochi_item_id: UUID) -> AnalysisInput | None:
        item = await GetMochiItemForOwner(repository=self._repo).execute(
            owner_id=owner_id, mochi_item_id=mochi_item_id
        )
        if item is None:
            return None
        bucket = get_settings().gcs_capture_bucket
        images: tuple[tuple[str, str], ...] = ()
        if bucket:
            images = tuple(
                (f"gs://{bucket}/{ref.object_key}", ref.mime_type)
                for ref in item.source.image_refs
                if ref.object_key
            )
        return AnalysisInput(
            text=item.source.text,
            url=item.source.url,
            user_memo=item.source.user_memo,
            analysis_ocr_text=item.source.analysis_ocr_text,
            images=images,
        )

    async def apply_analysis(self, *, owner_id: UUID, mochi_item_id: UUID, result: AnalysisResult) -> None:
        await self._repo.apply_analysis(
            owner_id=owner_id,
            mochi_item_id=mochi_item_id,
            intent_instances=result.intent_instances,
            needs_review=result.needs_review,
            review_options=result.review_options,
            summary=result.summary,
            category=result.category,
            importance=result.importance,
            model_version=result.model_version,
            entities=tuple((e.kind, e.value) for e in result.entities),
        )

    async def index_embedding(
        self,
        *,
        owner_id: UUID,
        mochi_item_id: UUID,
        chunk_text: str,
        embedding: list[float],
        model_version: str,
    ) -> None:
        await self._repo.replace_embedding(
            owner_id=owner_id,
            mochi_item_id=mochi_item_id,
            chunk_text=chunk_text,
            embedding=embedding,
            model_version=model_version,
        )

    async def list_recent_window(self, *, owner_id: UUID, limit: int) -> list[ProfileWindowItem]:
        items = await self._repo.list_recent(owner_id=owner_id, limit=max(limit, 80))
        cutoff = datetime.now(UTC) - timedelta(days=30)
        recent = [
            item
            for item in items
            if (
                (
                    item.source.captured_at
                    if item.source.captured_at.tzinfo
                    else item.source.captured_at.replace(tzinfo=UTC)
                )
                >= cutoff
            )
        ][:limit]
        return [
            ProfileWindowItem(
                mochi_item_id=it.id,
                summary=it.summary,
                title=it.display_title,
                category=it.category,
                intent_types=it.intent_types,
                user_memo=it.source.user_memo,
            )
            for it in recent
        ]

    async def list_category_vocabulary(self, *, owner_id: UUID, limit: int) -> list[str]:
        return await self._repo.list_category_vocabulary(owner_id=owner_id, limit=limit)

    async def count_items(self, *, owner_id: UUID) -> int:
        return await self._repo.count(owner_id=owner_id)
