"""트랙 C 후보 생성 저장소 — `RecallCandidateRepositoryPort` 구현 (P7~P9).

ANN 은 `recall_context_provider._similar` 와 동일한 pgvector `<=>` cosine 패턴(search 모듈을
cross-import 하면 경계 위반이라 raw SQL 직조회 — 임베딩 미설정 시 자연 0행). 가드 사실 조회는
worker `_run_guards` 와 같은 outbox 쿼리. 적재는 ORM(NotificationOutboxRow, event_id 자동 default).

콜론 토큰을 주석에 쓰지 않는다(SQLAlchemy text() 파싱).
"""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.notifications.domain.recall_candidate import (
    RecallCandidate,
    RecallCandidateRepositoryPort,
)
from app.modules.notifications.infrastructure.orm import NotificationOutboxRow


class PostgresRecallCandidateRepository(RecallCandidateRepositoryPort):
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_similar(
        self, *, owner_id: UUID, source_item_id: UUID, min_score: float, limit: int
    ) -> list[RecallCandidate]:
        sql = text(
            """
            WITH target AS (
                SELECT e.embedding AS emb
                FROM embeddings e
                JOIN mochi_items c ON c.id = e.mochi_item_id
                WHERE c.id = :target_id AND c.owner_id = :owner_id AND c.deleted_at IS NULL
                LIMIT 1
            )
            SELECT c.id AS item_id, c.summary AS summary, c.category AS category,
                   c.channel AS channel, 1.0 - (e.embedding <=> (SELECT emb FROM target)) AS score
            FROM embeddings e
            JOIN mochi_items c ON c.id = e.mochi_item_id
            WHERE c.owner_id = :owner_id
              AND c.deleted_at IS NULL
              AND c.id <> :target_id
              AND (SELECT emb FROM target) IS NOT NULL
              AND 1.0 - (e.embedding <=> (SELECT emb FROM target)) >= :min_score
            ORDER BY e.embedding <=> (SELECT emb FROM target)
            LIMIT :limit
            """
        ).bindparams(
            bindparam("target_id", source_item_id),
            bindparam("owner_id", owner_id),
            bindparam("min_score", min_score),
            bindparam("limit", limit),
        )
        rows = (await self._session.execute(sql)).all()
        return [
            RecallCandidate(
                item_id=row.item_id,
                score=float(row.score),
                summary=row.summary,
                category=row.category,
                channel=row.channel,
            )
            for row in rows
        ]

    async def recent_recall_exists(
        self, *, owner_id: UUID, source_item_id: UUID, since: datetime
    ) -> bool:
        stmt = text(
            """
            SELECT EXISTS(
              SELECT 1 FROM notification_outbox
              WHERE owner_id = :owner AND source_item_id = :item AND kind = 'recall'
                AND status IN ('pending','sent','deferred')
                AND created_at >= :since
            )
            """
        ).bindparams(
            bindparam("owner", owner_id),
            bindparam("item", source_item_id),
            bindparam("since", since),
        )
        return bool((await self._session.execute(stmt)).scalar())

    async def last_dismissed_for_intent(
        self, *, owner_id: UUID, source_intent_id: UUID | None
    ) -> datetime | None:
        if source_intent_id is None:
            return None
        stmt = text(
            "SELECT MAX(dismissed_at) FROM notification_outbox "
            "WHERE owner_id = :owner AND source_intent_id = :sid AND dismissed_at IS NOT NULL"
        ).bindparams(bindparam("owner", owner_id), bindparam("sid", source_intent_id))
        return (await self._session.execute(stmt)).scalar()

    async def same_day_count(self, *, owner_id: UUID, kst_date: date) -> int:
        stmt = text(
            """
            SELECT COUNT(*) FROM notification_outbox
            WHERE owner_id = :owner AND status IN ('pending','sent')
              AND (fire_at AT TIME ZONE 'Asia/Seoul')::date = :d
            """
        ).bindparams(bindparam("owner", owner_id), bindparam("d", kst_date))
        return int((await self._session.execute(stmt)).scalar() or 0)

    async def has_deadline_push_same_day(self, *, owner_id: UUID, kst_date: date) -> bool:
        stmt = text(
            """
            SELECT EXISTS(
              SELECT 1 FROM notification_outbox
              WHERE owner_id = :owner AND kind = 'deadline'
                AND status IN ('pending','sent')
                AND (fire_at AT TIME ZONE 'Asia/Seoul')::date = :d
            )
            """
        ).bindparams(bindparam("owner", owner_id), bindparam("d", kst_date))
        return bool((await self._session.execute(stmt)).scalar())

    async def insert_recall(
        self,
        *,
        owner_id: UUID,
        source_item_id: UUID,
        source_intent_id: UUID | None,
        fire_at: datetime,
        expires_at: datetime,
        title: str,
        body: str,
        collapse_id: str | None,
    ) -> UUID:
        # plan_id NULL 직행(kind=recall). event_id 는 ORM insert_default=uuid4 가 채운다.
        row = NotificationOutboxRow(
            owner_id=owner_id,
            kind="recall",
            fire_at=fire_at,
            title=title,
            body=body,
            source_item_id=source_item_id,
            source_intent_id=source_intent_id,
            expires_at=expires_at,
            collapse_id=collapse_id,
            status="pending",
        )
        self._session.add(row)
        await self._session.flush()
        return row.event_id

    async def recent_owner_recall_exists(self, *, owner_id: UUID, since: datetime) -> bool:
        stmt = text(
            """
            SELECT EXISTS(
              SELECT 1 FROM notification_outbox
              WHERE owner_id = :owner AND kind = 'recall'
                AND status IN ('pending','sent','deferred')
                AND created_at >= :since
            )
            """
        ).bindparams(bindparam("owner", owner_id), bindparam("since", since))
        return bool((await self._session.execute(stmt)).scalar())

    async def acquire_owner_lock(self, *, owner_id: UUID) -> None:
        # 발송 워커(_materialize_one_plan)와 동일 키 공간 hashtext(owner) — 동시 저장 직렬화.
        await self._session.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:owner))").bindparams(owner=str(owner_id))
        )
