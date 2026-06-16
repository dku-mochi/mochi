"""능동 회수 홈 피드 + 알림 landing(P5b) 유스케이스 — 후보 하이드레이션 + 표시 entry 조립.

정본 `journal/2026-06-15-proactive-recall-ux-decision.md` §4. 트랙 C(관련/맥락)는 범위 밖이라
모든 entry 가 kind="knowledge", reason="fadingValue"(spaced 회수="잊기 전에 한 번"), related=[].

후보(item_id)는 `RecallFeedRepositoryPort`(notification 테이블)가, 표시필드(title/summary/channel/
saved_at)는 cross-module `MochiItemRepository`(application factory)가 하이드레이션한다 — 모듈 경계.
삭제(find_by_id None)·비-knowledge·archived knowledge 만 있는 item 은 피드에서 거른다.

oneline(미리보기 1줄)·gist(상세 핵심 bullet)는 item.summary 를 분할한다 — 별도 핵심 추출
파이프라인(트랙 C 후속)이 없어 summary 가 단일 원천. 분할은 단순(줄바꿈/문장), 없으면 빈 처리.
"""

import re
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleKind
from app.modules.notifications.domain.recall_feed import RecallFeedRepositoryPort
from app.shared.intent import Intent

# spaced 회수의 표시 상수 — 트랙 A/B 에선 피드가 곧 "다시 볼 지식"이라 고정.
_KIND_KNOWLEDGE = "knowledge"
_REASON_FADING_VALUE = "fadingValue"  # spaced = "잊기 전에 한 번"(RecallReason.fadingValue)
# gist bullet 상한 — 상세 화면 "모찌가 정리한 핵심"이 과하게 길어지지 않게(개인 사용 규모 충분).
_MAX_GIST = 5
# "다시 볼" 살아있는 knowledge lifecycle — archived 는 사용자가 이미 닫아 회수 대상 아님.
_LIVE_KINDS = frozenset(
    {
        InstanceLifecycleKind.ACTIVE,
        InstanceLifecycleKind.DECAYING,
        InstanceLifecycleKind.REVIEW_REQUESTED,
    }
)


@dataclass(frozen=True, slots=True)
class RecallFeedEntry:
    """iOS RecallEntry 표시모델 매핑(UI 전용 color/symbol/grad 제외 — iOS 가 reason→매핑)."""

    item_id: UUID
    kind: str
    reason: str
    title: str
    oneline: str
    source: str
    saved_at: datetime
    gist: list[str]
    related: list[object]  # 트랙 C 후속 — 현재 항상 []
    related_count: int
    recall_event_id: UUID | None


def _split_summary(summary: str | None) -> tuple[str, list[str]]:
    """summary → (oneline, gist[]). 줄바꿈 우선, 없으면 문장 단위. 빈 summary 면 ("", [])."""
    if not summary or not summary.strip():
        return "", []
    lines = [ln.strip() for ln in summary.strip().splitlines() if ln.strip()]
    if len(lines) <= 1:
        # 한 덩어리 — 문장 부호로 쪼갠다(한국어/영문 './!/?/。' + 뒤 공백).
        whole = lines[0] if lines else summary.strip()
        lines = [s.strip() for s in re.split(r"(?<=[.!?。])\s+", whole) if s.strip()]
    oneline = lines[0] if lines else ""
    return oneline, lines[:_MAX_GIST]


def _has_live_knowledge(item: MochiItem) -> bool:
    return any(
        inst.intent_type is Intent.KNOWLEDGE and inst.lifecycle.kind in _LIVE_KINDS
        for inst in item.intent_instances
    )


def _to_entry(item: MochiItem, *, recall_event_id: UUID | None) -> RecallFeedEntry:
    oneline, gist = _split_summary(item.summary)
    return RecallFeedEntry(
        item_id=item.id,
        kind=_KIND_KNOWLEDGE,
        reason=_REASON_FADING_VALUE,
        title=item.display_title or "",
        oneline=oneline,
        source=item.source.channel.value,
        saved_at=item.source.captured_at,
        gist=gist,
        related=[],
        related_count=1,
        recall_event_id=recall_event_id,
    )


@dataclass(slots=True)
class GetRecallFeed:
    """홈 회수 한 칸 + 자세히 목록 — owner 의 active spaced plan knowledge 를 entry 로."""

    feed: RecallFeedRepositoryPort
    mochi_items: MochiItemRepository

    async def execute(self, *, owner_id: UUID, limit: int) -> list[RecallFeedEntry]:
        candidates = await self.feed.list_candidates(owner_id=owner_id, limit=limit)
        entries: list[RecallFeedEntry] = []
        for cand in candidates:
            item = await self.mochi_items.find_by_id(
                owner_id=owner_id, mochi_item_id=cand.item_id
            )
            # 삭제됨(find_by_id None) 또는 살아있는 knowledge instance 없음 → 피드 제외.
            if item is None or not _has_live_knowledge(item):
                continue
            entries.append(_to_entry(item, recall_event_id=cand.recall_event_id))
        return entries


@dataclass(slots=True)
class GetRecallLanding:
    """알림 landing fallback — recallEventID 로 단건 entry(iOS 로컬 역매핑 실패 시 서버 fetch).

    reaction(sent 제한)과 달리 조회는 status 무관 — sent 후 탭이라도 보여야 한다. owner 스코프는 필수.
    landing 은 단건 표시라 live-knowledge 필터를 걸지 않는다(탭한 그 항목을 보여준다). 삭제·미실재면 404.
    """

    feed: RecallFeedRepositoryPort
    mochi_items: MochiItemRepository

    async def execute(self, *, owner_id: UUID, event_id: UUID) -> RecallFeedEntry:
        item_id = await self.feed.resolve_landing(owner_id=owner_id, event_id=event_id)
        if item_id is None:
            raise NotFoundError("Recall event not found", code="recall_event.not_found")
        item = await self.mochi_items.find_by_id(owner_id=owner_id, mochi_item_id=item_id)
        if item is None:
            raise NotFoundError("Recall event not found", code="recall_event.not_found")
        return _to_entry(item, recall_event_id=event_id)
