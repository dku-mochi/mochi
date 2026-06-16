"""능동 회수 알림 반응 기록(P5) 유스케이스 — opened/dismissed/stop + spaced 소생.

정본 `journal/proactive-recall/notification-agent.md` §5(반응 수집·codex-6 멱등) /
`ux-ui.md` §4("그만" scope 1:1 codex-7)·§5(소생) / `docs/DOMAIN_DESIGN.md` §5.2("회수로 소생").

멱등·보안(codex-6): `(event_id, owner_id)` + `status='sent'` 인 행만 atomic UPDATE 가드로 친다.
0행이면 sent 행 존재 여부로 분기 — 존재→멱등 no-op, 미존재→404(남의 event_id·중복 탭 방어).

신호 의미(§6): opened 만 양성. dismissed/stop=명시 부정. 여기선 기록만(학습 후속).
"""

from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.core.logging import get_logger
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.application.update_instance_lifecycle import (
    UpdateInstanceLifecycle,
    UpdateInstanceLifecycleCommand,
)
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    InstanceLifecycleState,
)
from app.modules.notifications.domain.recall_reaction import (
    ReactionKind,
    RecallReactionRepositoryPort,
    SentRecallEvent,
)
from app.shared.intent import Intent

log = get_logger("notifications.record_reaction")

# spaced 소생 대상 = 회수로 다시 살아나는 knowledge lifecycle (lifecycle_policy 가 →active 허용).
_REVIVABLE_KINDS = frozenset(
    {InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.REVIEW_REQUESTED}
)
_SPACED_KIND = "spaced"


@dataclass(slots=True)
class RecordRecallReactionCommand:
    owner_id: UUID
    event_id: UUID
    reaction: ReactionKind


class RecordRecallReaction:
    """알림 반응 1건을 outbox 에 멱등 기록 + stop plan cancel + opened+spaced 소생.

    소생(`mochi_items`)은 cross-module 이라 application factory 가 만든 `MochiItemRepository` +
    `UpdateInstanceLifecycle` 만 쓴다(infrastructure 직접 reach 금지).
    """

    def __init__(
        self,
        *,
        reactions: RecallReactionRepositoryPort,
        mochi_items: MochiItemRepository,
    ) -> None:
        self._reactions = reactions
        self._mochi_items = mochi_items

    async def execute(self, command: RecordRecallReactionCommand) -> None:
        # atomic UPDATE 의 가드 컨텍스트 + 소생 정보를 한 번에 읽는다(0행 분기·spaced 소생 공용).
        event = await self._reactions.find_sent_event(
            event_id=command.event_id, owner_id=command.owner_id
        )
        if event is None:
            # sent 행이 없다 — 남의 event_id·pending·이미 종료 → 404(멱등 no-op 과 구분).
            raise NotFoundError("Recall event not found", code="recall_event.not_found")

        if command.reaction is ReactionKind.OPENED:
            await self._handle_opened(command, event)
        elif command.reaction is ReactionKind.DISMISSED:
            # soft 부정(cooldown 신호) — 멱등 atomic UPDATE. 0행=이미 dismissed(no-op).
            await self._reactions.mark_dismissed(
                event_id=command.event_id, owner_id=command.owner_id
            )
        else:  # ReactionKind.STOP — "이 기억 그만" 영구(codex-7)
            await self._handle_stop(command, event)

    async def _handle_opened(
        self, command: RecordRecallReactionCommand, event: SentRecallEvent
    ) -> None:
        # first-write-wins — opened_at IS NULL 인 sent 행에만 기록. 1행=이번이 첫 탭(소생 트리거),
        # 0행=이미 opened(중복 탭 멱등 no-op, 소생 재시도 안 함).
        updated = await self._reactions.mark_opened(
            event_id=command.event_id, owner_id=command.owner_id
        )
        if updated and event.kind == _SPACED_KIND:
            # HIGH-2: 회수로 소생. best-effort — 실패가 opened_at 기록을 롤백/실패시키지 않게 격리.
            await self._revive_spaced(command, event)

    async def _handle_stop(
        self, command: RecordRecallReactionCommand, event: SentRecallEvent
    ) -> None:
        # dismissed_at 세팅(멱등) + plan 영구 취소. plan_id NULL(트랙C)이면 plan 변경 생략.
        await self._reactions.mark_dismissed(
            event_id=command.event_id, owner_id=command.owner_id
        )
        if event.plan_id is not None:
            await self._reactions.cancel_plan(
                plan_id=event.plan_id, owner_id=command.owner_id
            )

    async def _revive_spaced(
        self, command: RecordRecallReactionCommand, event: SentRecallEvent
    ) -> None:
        """opened+spaced 면 source knowledge instance 를 decaying/reviewRequested → active 로 소생.

        best-effort: 어떤 실패(item/instance 없음·다른 owner·비-knowledge·전이 불가)도 삼켜서
        반응 기록(opened_at)을 보존한다. active/archived 등 다른 상태면 no-op.
        """
        if event.source_item_id is None or event.source_intent_id is None:
            return
        try:
            item = await self._mochi_items.find_by_id(
                owner_id=command.owner_id, mochi_item_id=event.source_item_id
            )
            if item is None:
                return
            instance = next(
                (i for i in item.intent_instances if i.id == event.source_intent_id),
                None,
            )
            if instance is None:
                return
            if instance.intent_type is not Intent.KNOWLEDGE:
                return  # 비-knowledge 면 소생 대상 아님(no-op)
            if instance.lifecycle.kind not in _REVIVABLE_KINDS:
                return  # active/archived 등 — 소생 불필요(no-op)
            target = InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE)
            # 방어적 재확인 — lifecycle_policy 가 decaying/reviewRequested→active 를 허용해야만 전이.
            if not is_allowed(instance.intent_type, instance.lifecycle, target):
                return
            # savepoint(P1#4) — 소생 write 가 DB 에러를 던져도 이 savepoint 만 롤백되고 outer 트랜잭션
            # (이미 flush 된 opened_at)이 aborted 되지 않는다. except 가 예외를 삼켜 best-effort 격리.
            async with self._reactions.savepoint():
                await UpdateInstanceLifecycle(repository=self._mochi_items).execute(
                    UpdateInstanceLifecycleCommand(
                        owner_id=command.owner_id,
                        mochi_item_id=event.source_item_id,
                        instance_id=event.source_intent_id,
                        target=target,
                    )
                )
            log.info(
                "recall.revive_spaced",
                owner_id=str(command.owner_id),
                event_id=str(command.event_id),
                mochi_item_id=str(event.source_item_id),
                instance_id=str(event.source_intent_id),
                frm=instance.lifecycle.kind.value,
            )
        except Exception as exc:  # noqa: BLE001 - 소생 실패가 반응 기록을 깨면 안 됨(격리)
            log.warning(
                "recall.revive_spaced_failed",
                owner_id=str(command.owner_id),
                event_id=str(command.event_id),
                exception=str(exc),
            )
