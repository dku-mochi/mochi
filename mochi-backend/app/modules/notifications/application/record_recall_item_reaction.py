"""능동 회수 피드 반응(item 기준) 유스케이스 — 피드 open/stop 이 event 없이도 서버에 남게.

배경(2026-07-10 피드 카드 부활 버그): 피드 표면(홈 "모찌가 골라봤어요"·자세히·회수 상세)의
open/stop 보고가 event 기준(`POST /recall/events/{id}/reaction`)이라 두 경우에 유실됐다 —
① 트랙 A(spaced) 후보는 sent event 가 없으면 recall_event_id=NULL 이라 iOS 가 보고를 생략하고
(dry_run 환경에선 sent 가 아예 없어 항상 NULL), ② 트랙 C(recall 직행) 후보는 pending event 를
피드에 노출하는데 reaction 의 status='sent' 가드에 걸려 404. 어느 쪽도 서버에 안 남아 재fetch
마다 카드가 부활했다. 피드 카드는 event 유무와 무관하게 존재하므로 피드 반응은 item 기준으로
받는다. 알림 표면(푸시 탭 landing·지난 알림)은 계속 event 기준(`RecordRecallReaction`) —
발송 1건과 1:1 인 학습 신호라 의미가 다르다.

- opened: ① 트랙 C 종결 — kind='recall' pending/sent 행에 opened_at(+pending 은 skipped(opened)
  로 종결해 이미 본 카드의 뒷북 푸시 방지; sent 는 피드 쿼리의 opened 필터가 제외).
  ② 트랙 A 소생 — 그 item 의 decaying/reviewRequested knowledge instance → active
  (DOMAIN_DESIGN §5.2 와 동일 전이, 피드의 live-knowledge 필터에서 자동으로 빠짐). best-effort.
- stop: ① 그 item 의 active spaced plan 전부 cancelled(user_dismiss) ② kind='recall'
  pending/sent 행 skipped(cancelled)+dismissed_at(재생성 dismiss-cooldown 신호 보존).
- dismissed: 피드 표면에 없는 제스처 — 400.
"""

from dataclasses import dataclass
from uuid import UUID

from app.core.error_envelope import DomainError, NotFoundError
from app.core.logging import get_logger
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.application.update_instance_lifecycle import (
    UpdateInstanceLifecycle,
    UpdateInstanceLifecycleCommand,
)
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    InstanceLifecycleState,
)
from app.modules.notifications.domain.recall_reaction import (
    ReactionKind,
    RecallReactionRepositoryPort,
)
from app.shared.intent import Intent

log = get_logger("notifications.record_item_reaction")

# 소생 대상 lifecycle — record_recall_reaction._REVIVABLE_KINDS 와 동일 정책(피드 open = 회수 소비).
_REVIVABLE_KINDS = frozenset({InstanceLifecycleKind.DECAYING, InstanceLifecycleKind.REVIEW_REQUESTED})


@dataclass(slots=True)
class RecordRecallItemReactionCommand:
    owner_id: UUID
    item_id: UUID
    reaction: ReactionKind


class RecordRecallItemReaction:
    """피드 표면의 opened/stop 을 item 기준으로 기록 + 소생/plan cancel. 멱등(재호출 no-op).

    소생(`mochi_items`)은 cross-module 이라 application factory 가 만든 `MochiItemRepository` +
    `UpdateInstanceLifecycle` 만 쓴다(infrastructure 직접 reach 금지 — RecordRecallReaction 컨벤션).
    """

    def __init__(
        self,
        *,
        reactions: RecallReactionRepositoryPort,
        mochi_items: MochiItemRepository,
    ) -> None:
        self._reactions = reactions
        self._mochi_items = mochi_items

    async def execute(self, command: RecordRecallItemReactionCommand) -> None:
        if command.reaction is ReactionKind.DISMISSED:
            # 피드 카드엔 soft-dismiss 제스처가 없다 — event 기준 반응(알림 표면)만의 의미.
            raise DomainError(
                "dismissed is not a feed reaction",
                code="recall_item_reaction.unsupported",
            )
        item = await self._mochi_items.find_by_id(owner_id=command.owner_id, mochi_item_id=command.item_id)
        if item is None:
            # 삭제·남의 item — owner 스코프 조회라 cross-tenant 도 여기서 404.
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")
        if command.reaction is ReactionKind.OPENED:
            await self._handle_opened(command, item)
        else:  # ReactionKind.STOP — "이 기억 그만"(피드 표면, codex-7 과 동일 영구 의미)
            await self._handle_stop(command)

    async def _handle_opened(self, command: RecordRecallItemReactionCommand, item: MochiItem) -> None:
        # 트랙 C 먼저 기록(멱등 UPDATE) — 소생이 실패해도 opened 기록은 남게(격리 순서).
        await self._reactions.open_recall_rows_for_item(owner_id=command.owner_id, item_id=command.item_id)
        await self._revive_knowledge(command, item)

    async def _handle_stop(self, command: RecordRecallItemReactionCommand) -> None:
        # 트랙 A — active spaced plan 전부 영구 취소(+cancel_plan 이 그 plan 의 미발송 outbox 정리).
        plan_ids = await self._reactions.list_active_spaced_plan_ids(
            owner_id=command.owner_id, source_item_id=command.item_id
        )
        for plan_id in plan_ids:
            await self._reactions.cancel_plan(plan_id=plan_id, owner_id=command.owner_id)
        # 트랙 C — pending/sent 행 종결 + dismissed_at(재생성 쿨다운 신호).
        await self._reactions.stop_recall_rows_for_item(owner_id=command.owner_id, item_id=command.item_id)

    async def _revive_knowledge(self, command: RecordRecallItemReactionCommand, item: MochiItem) -> None:
        """피드 open = 회수 소비 — decaying/reviewRequested knowledge instance 를 active 로 소생.

        best-effort: 어떤 실패(전이 불가·DB 에러)도 삼켜서 opened 기록(트랙 C UPDATE)을 보존한다.
        savepoint(P1#4) — 소생 write 의 DB 에러가 outer 트랜잭션을 aborted 시키지 않게 격리.
        """
        try:
            for instance in item.intent_instances:
                if instance.intent_type is not Intent.KNOWLEDGE:
                    continue
                if instance.lifecycle.kind not in _REVIVABLE_KINDS:
                    continue  # active/archived 등 — 소생 불필요(no-op)
                target = InstanceLifecycleState(kind=InstanceLifecycleKind.ACTIVE)
                # 방어적 재확인 — lifecycle_policy 가 decaying/reviewRequested→active 를 허용해야만 전이.
                if not is_allowed(instance.intent_type, instance.lifecycle, target):
                    continue
                async with self._reactions.savepoint():
                    await UpdateInstanceLifecycle(repository=self._mochi_items).execute(
                        UpdateInstanceLifecycleCommand(
                            owner_id=command.owner_id,
                            mochi_item_id=command.item_id,
                            instance_id=instance.id,
                            target=target,
                        )
                    )
                log.info(
                    "recall.revive_from_feed",
                    owner_id=str(command.owner_id),
                    mochi_item_id=str(command.item_id),
                    instance_id=str(instance.id),
                    frm=instance.lifecycle.kind.value,
                )
        except Exception as exc:  # noqa: BLE001 - 소생 실패가 반응 기록을 깨면 안 됨(격리)
            log.warning(
                "recall.revive_from_feed_failed",
                owner_id=str(command.owner_id),
                mochi_item_id=str(command.item_id),
                exception=str(exc),
            )
