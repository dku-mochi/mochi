"""/recall/* 라우터 — 능동 회수 홈 피드·알림 landing 조회(P5b) + 알림 반응 수집(P5).

조회(P5b): `GET /recall/feed`(홈 한 칸·자세히 목록), `GET /recall/events/{id}`(알림 landing fallback —
iOS 로컬 역매핑 실패 시 recallEventID 로 서버 fetch). 트랙 A/B 의 피드 실데이터는 active spaced plan 이
걸린 knowledge(다시 볼 지식)뿐이다(`journal/2026-06-15-proactive-recall-ux-decision.md` §4·§5).

반응(P5): iOS 가 알림 탭(opened)·dismiss(dismissed)·"이 기억 그만"(stop) 시 `recallEventID`(=outbox.event_id)
로 보고한다. 멱등·owner 가드는 application(`RecordRecallReaction`) + infrastructure atomic UPDATE.
opened+spaced 면 회수로 knowledge 를 소생(ux-ui.md §5 / DOMAIN_DESIGN.md §5.2).
"""

from uuid import UUID

from fastapi import APIRouter, status
from fastapi.responses import Response

from app.core.deps import DBSession
from app.core.security import CurrentUser
from app.modules.mochi_items.application.queries import make_mochi_item_repository
from app.modules.notifications.application.get_recall_feed import (
    GetRecallFeed,
    GetRecallLanding,
)
from app.modules.notifications.application.get_recall_feed import (
    RecallFeedEntry as RecallFeedEntryDTO,
)
from app.modules.notifications.application.record_recall_reaction import (
    RecordRecallReaction,
    RecordRecallReactionCommand,
)
from app.modules.notifications.infrastructure.recall_feed_repository import (
    PostgresRecallFeedRepository,
)
from app.modules.notifications.infrastructure.recall_reaction_repository import (
    PostgresRecallReactionRepository,
)
from app.modules.notifications.presentation.schemas import (
    RecallFeedEntry,
    RecallFeedResponse,
    RecordRecallReactionRequest,
)

router = APIRouter(prefix="/recall", tags=["recall"])


def _entry_to_response(entry: RecallFeedEntryDTO) -> RecallFeedEntry:
    return RecallFeedEntry(
        item_id=entry.item_id,
        kind=entry.kind,
        reason=entry.reason,
        title=entry.title,
        oneline=entry.oneline,
        source=entry.source,
        saved_at=entry.saved_at,
        gist=entry.gist,
        related=[],  # 트랙 C 후속 — application 도 항상 [] 를 낸다
        related_count=entry.related_count,
        recall_event_id=entry.recall_event_id,
    )


@router.get("/feed", response_model=RecallFeedResponse)
async def get_recall_feed(
    db: DBSession,
    user: CurrentUser,
    limit: int = 20,
) -> RecallFeedResponse:
    """홈 회수 한 칸 + 자세히 목록 — owner 의 active spaced plan knowledge(다시 볼 지식).

    소스: notification_plan(status='active', plan_kind='spaced') → source item(deleted_at IS NULL,
    살아있는 knowledge instance). recency 정렬(랭킹 공식 미정 — 후속). 빈손이면 entries=[](정상).
    """
    use_case = GetRecallFeed(
        feed=PostgresRecallFeedRepository(db),
        mochi_items=make_mochi_item_repository(db),
    )
    entries = await use_case.execute(owner_id=user, limit=max(1, min(limit, 50)))
    return RecallFeedResponse(entries=[_entry_to_response(e) for e in entries])


@router.get("/events/{event_id}", response_model=RecallFeedEntry)
async def get_recall_landing(
    event_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> RecallFeedEntry:
    """알림 landing fallback — recallEventID 로 단건 회수 entry(iOS 로컬 역매핑 실패 시 서버 fetch).

    owner+event 로 outbox→item 해석. status 무관(sent 후 탭이라도 보여야 함). 남의 event·삭제·미실재 404.
    """
    use_case = GetRecallLanding(
        feed=PostgresRecallFeedRepository(db),
        mochi_items=make_mochi_item_repository(db),
    )
    entry = await use_case.execute(owner_id=user, event_id=event_id)
    return _entry_to_response(entry)


@router.post("/events/{event_id}/reaction", status_code=status.HTTP_204_NO_CONTENT)
async def record_recall_reaction(
    event_id: UUID,
    payload: RecordRecallReactionRequest,
    db: DBSession,
    user: CurrentUser,
) -> Response:
    """알림 반응 보고 (owner-scoped, first-write-wins 멱등).

    `(event_id, owner_id)` + `status='sent'` 인 행만 갱신한다. 행이 없으면 404(남의 event_id·
    pending·이미 종료). 이미 같은 반응이 기록돼 있으면 멱등 no-op(중복 탭 → 204).
    """
    use_case = RecordRecallReaction(
        reactions=PostgresRecallReactionRepository(db),
        mochi_items=make_mochi_item_repository(db),
    )
    await use_case.execute(
        RecordRecallReactionCommand(
            owner_id=user,
            event_id=event_id,
            reaction=payload.reaction,
        )
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
