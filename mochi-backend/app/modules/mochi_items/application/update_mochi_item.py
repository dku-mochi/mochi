"""PATCH /mochi_items/{id} — 채팅 수정 proposal 확정의 실행 유스케이스 (journal 2026-06-10 M1).

콘텐츠 필드(text/user_memo/summary)와 instance 변경(payload 병합·label·lifecycle 전이)을
**한 요청·한 트랜잭션**으로 처리한다 — proposal 카드 확정 = REST 1콜 (부분 적용 실패 모드 회피).

- payload 는 **병합**("이 일정 3시로 바꿔줘"는 time 만 바꾸고 나머지 보존) — 전체 교체는
  repository 에 맡기고 병합 계산은 여기서.
- lifecycle 전이는 ``lifecycle_policy.is_allowed`` 검증(불법 409) + 멱등(동일 상태 no-op) —
  ``UpdateInstanceLifecycle`` 과 동일 규약.
- instance 미실재는 404(`intent_instance.not_found`) — 카드 생성~확정 사이 reanalyze 가
  instance 를 delete-reinsert 하는 known-drift 의 만료 신호. iOS 가 카드를 expired 처리한다.
"""

from dataclasses import dataclass, field
from uuid import UUID

from app.core.error_envelope import ConflictError, NotFoundError
from app.modules.intents.domain.lifecycle_policy import is_allowed
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleState


@dataclass(slots=True, frozen=True)
class InstanceChange:
    instance_id: UUID
    payload_fields: dict[str, str] = field(default_factory=dict)  # 병합할 필드만
    label: str | None = None
    lifecycle: InstanceLifecycleState | None = None


@dataclass(slots=True, frozen=True)
class UpdateMochiItemCommand:
    owner_id: UUID
    mochi_item_id: UUID
    text: str | None = None
    user_memo: str | None = None
    summary: str | None = None
    instance_changes: tuple[InstanceChange, ...] = ()


class UpdateMochiItem:
    def __init__(self, repository: MochiItemRepository):
        self._repo = repository

    async def execute(self, command: UpdateMochiItemCommand) -> MochiItem:
        item = await self._repo.find_by_id(owner_id=command.owner_id, mochi_item_id=command.mochi_item_id)
        if item is None:
            raise NotFoundError("Mochi item not found", code="mochi_item.not_found")

        # 검증을 전부 끝낸 뒤 쓰기 시작 — 한 트랜잭션이지만 검증 실패 시 쓰기 자체가 없게.
        resolved: list[tuple[InstanceChange, dict[str, str] | None]] = []
        for change in command.instance_changes:
            instance = next((i for i in item.intent_instances if i.id == change.instance_id), None)
            if instance is None:
                raise NotFoundError("Intent instance not found", code="intent_instance.not_found")
            if (
                change.lifecycle is not None
                and instance.lifecycle != change.lifecycle
                and not is_allowed(instance.intent_type, instance.lifecycle, change.lifecycle)
            ):
                raise ConflictError(
                    f"Illegal lifecycle transition for {instance.intent_type.value}: "
                    f"{instance.lifecycle.kind.value} → {change.lifecycle.kind.value}",
                    code="intent_instance.illegal_transition",
                )
            merged: dict[str, str] | None = None
            if change.payload_fields:
                current = {
                    key: value
                    for key, value in {
                        "title": instance.payload.title,
                        "date": instance.payload.date,
                        "time": instance.payload.time,
                        "end_date": instance.payload.end_date,
                        "end_time": instance.payload.end_time,
                        "deadline": instance.payload.deadline,
                        "person": instance.payload.person,
                        "topic": instance.payload.topic,
                        "url": instance.payload.url,
                        "note": instance.payload.note,
                    }.items()
                    if value is not None
                }
                merged = {**current, **change.payload_fields}
            resolved.append((change, merged))

        await self._repo.update_content(
            owner_id=command.owner_id,
            mochi_item_id=command.mochi_item_id,
            text=command.text,
            user_memo=command.user_memo,
            summary=command.summary,
        )
        for change, merged in resolved:
            if merged is not None or change.label is not None:
                updated = await self._repo.update_instance_fields(
                    owner_id=command.owner_id,
                    mochi_item_id=command.mochi_item_id,
                    instance_id=change.instance_id,
                    payload=merged,
                    label=change.label,
                )
                if not updated:
                    raise NotFoundError("Intent instance not found", code="intent_instance.not_found")
            if change.lifecycle is not None:
                instance = next(i for i in item.intent_instances if i.id == change.instance_id)
                if instance.lifecycle != change.lifecycle:  # 멱등 — 동일 상태 no-op
                    updated = await self._repo.update_instance_lifecycle(
                        owner_id=command.owner_id,
                        mochi_item_id=command.mochi_item_id,
                        instance_id=change.instance_id,
                        lifecycle=change.lifecycle,
                    )
                    if not updated:
                        raise NotFoundError("Intent instance not found", code="intent_instance.not_found")

        refreshed = await self._repo.find_by_id(
            owner_id=command.owner_id, mochi_item_id=command.mochi_item_id
        )
        assert refreshed is not None  # 같은 트랜잭션 안 — 방금 존재 확인했다
        return refreshed
