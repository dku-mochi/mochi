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
from app.modules.notifications.application.get_sent_notifications import (
    GetSentNotifications,
)
from app.modules.notifications.application.get_upcoming_notifications import (
    GetUpcomingNotifications,
)
from app.modules.notifications.application.override_upcoming_notification import (
    RescheduleUpcomingCommand,
    RescheduleUpcomingNotification,
    VetoUpcomingCommand,
    VetoUpcomingNotification,
)
from app.modules.notifications.application.record_recall_reaction import (
    RecordRecallReaction,
    RecordRecallReactionCommand,
)
from app.modules.notifications.domain.sent_feed import (
    SentNotification as SentNotificationDTO,
)
from app.modules.notifications.domain.upcoming_feed import (
    UpcomingNotification as UpcomingNotificationDTO,
)
from app.modules.notifications.infrastructure.recall_candidate_repository import (
    PostgresRecallCandidateRepository,
)
from app.modules.notifications.infrastructure.recall_feed_repository import (
    PostgresRecallFeedRepository,
)
from app.modules.notifications.infrastructure.recall_reaction_repository import (
    PostgresRecallReactionRepository,
)
from app.modules.notifications.infrastructure.sent_feed_repository import (
    PostgresSentFeedRepository,
)
from app.modules.notifications.infrastructure.upcoming_feed_repository import (
    PostgresUpcomingFeedRepository,
)
from app.modules.notifications.infrastructure.upcoming_override_repository import (
    PostgresUpcomingOverrideRepository,
)
from app.modules.notifications.presentation.schemas import (
    RecallFeedEntry,
    RecallFeedResponse,
    RecordRecallReactionRequest,
    RelatedItem,
    RescheduleUpcomingRequest,
    SentNotificationEntry,
    SentNotificationsResponse,
    UpcomingNotificationEntry,
    UpcomingNotificationsResponse,
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
        related=[
            RelatedItem(item_id=r.item_id, title=r.title, oneline=r.oneline)
            for r in entry.related
        ],
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
        candidates=PostgresRecallCandidateRepository(db),
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
        candidates=PostgresRecallCandidateRepository(db),
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


def _upcoming_to_response(n: UpcomingNotificationDTO) -> UpcomingNotificationEntry:
    return UpcomingNotificationEntry(
        event_id=n.event_id,
        kind=n.kind,
        fire_at=n.fire_at,
        title=n.title,
        body=n.body,
        original_fire_at=n.original_fire_at,
        item_id=n.item_id,
        intent_id=n.intent_id,
    )


@router.get("/upcoming", response_model=UpcomingNotificationsResponse)
async def get_upcoming_notifications(
    db: DBSession,
    user: CurrentUser,
    limit: int = 20,
) -> UpcomingNotificationsResponse:
    """홈탭 "예정 알림" — owner 의 아직 안 보낸 미래 알림(마감/일정, fire_at>now) fire_at 오름차순.

    "언제 알림이 갈지" 미리 보여줘 안심시키는 예고. spaced 회수는 RecallHero 담당이라 제외.
    빈손이면 entries=[](정상).
    """
    use_case = GetUpcomingNotifications(feed=PostgresUpcomingFeedRepository(db))
    items = await use_case.execute(owner_id=user, limit=max(1, min(limit, 50)))
    return UpcomingNotificationsResponse(
        entries=[_upcoming_to_response(n) for n in items]
    )


@router.post("/upcoming/{event_id}/reschedule", status_code=status.HTTP_204_NO_CONTENT)
async def reschedule_upcoming_notification(
    event_id: UUID,
    payload: RescheduleUpcomingRequest,
    db: DBSession,
    user: CurrentUser,
) -> Response:
    """예정 알림의 발송 시각을 사용자 지정 시각으로 옮긴다(프리셋·DatePicker 공용, owner-scoped).

    pending(fire_at>now) 인 행만 갱신 + 첫 1회 원안 보존. 행이 없으면 404(남의 event·이미 발송).
    과거 시각이면 422(`recall_upcoming.past_fire_at`).
    """
    use_case = RescheduleUpcomingNotification(
        override=PostgresUpcomingOverrideRepository(db)
    )
    await use_case.execute(
        RescheduleUpcomingCommand(
            owner_id=user, event_id=event_id, new_fire_at=payload.fire_at
        )
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/upcoming/{event_id}/veto", status_code=status.HTTP_204_NO_CONTENT)
async def veto_upcoming_notification(
    event_id: UUID,
    db: DBSession,
    user: CurrentUser,
) -> Response:
    """이 항목 알림 전체 끄기 — 대상 pending skip(user_veto) + 그 plan 영구 cancel(user_dismiss).

    그 plan 의 나머지 미래 단계 알림도 함께 정지된다. 행이 없으면 404(남의 event·이미 발송/취소).
    """
    use_case = VetoUpcomingNotification(
        override=PostgresUpcomingOverrideRepository(db),
        reactions=PostgresRecallReactionRepository(db),
    )
    await use_case.execute(VetoUpcomingCommand(owner_id=user, event_id=event_id))
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _sent_to_response(n: SentNotificationDTO) -> SentNotificationEntry:
    return SentNotificationEntry(
        event_id=n.event_id,
        kind=n.kind,
        sent_at=n.sent_at,
        opened_at=n.opened_at,
        dismissed_at=n.dismissed_at,
        title=n.title,
        body=n.body,
        item_id=n.item_id,
        intent_id=n.intent_id,
    )


@router.get("/history", response_model=SentNotificationsResponse)
async def get_sent_notifications(
    db: DBSession,
    user: CurrentUser,
    limit: int = 20,
) -> SentNotificationsResponse:
    """알림 페이지 "지난 알림" — owner 의 이미 보낸 알림(status='sent') sent_at 내림차순.

    종류 무관(받은 알림 전부). opened_at/dismissed_at 로 열어봤는지 표시. 빈손이면 entries=[].
    """
    use_case = GetSentNotifications(feed=PostgresSentFeedRepository(db))
    items = await use_case.execute(owner_id=user, limit=max(1, min(limit, 50)))
    return SentNotificationsResponse(
        entries=[_sent_to_response(n) for n in items]
    )
