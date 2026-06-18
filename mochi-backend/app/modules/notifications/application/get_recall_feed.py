"""능동 회수 홈 피드 + 알림 landing(P5b) 유스케이스 — 후보 하이드레이션 + 표시 entry 조립.

정본 `journal/2026-06-15-proactive-recall-ux-decision.md` §4. 두 소스를 합류한다:
- 트랙 A(spaced): active spaced plan knowledge → kind="knowledge", reason="fadingValue", related=[].
- 트랙 C(recall): kind=recall outbox 직행 앵커 → kind="recall", reason="linkedToRecent",
  related=앵커 item 의 ANN 이웃(관련 기억 N개). related 는 캐시하지 않고 조회 시점에 재실행.

후보(item_id/source_kind/recall_event_id)는 `RecallFeedRepositoryPort`(notification 테이블)가, 표시필드
(title/summary/channel/saved_at)는 cross-module `MochiItemRepository`(application factory)가 하이드레이션.
related 는 `RecallCandidateRepositoryPort`(ANN)로 채운다. 삭제(find_by_id None)·비-knowledge·archived
knowledge 만 있는 spaced item 은 피드에서 거른다(recall 은 kind 무관이라 필터 안 함).

oneline(미리보기 1줄)·gist(상세 핵심 bullet)는 item.summary 를 분할한다 — 별도 핵심 추출 파이프라인
(트랙 C 후속)이 없어 summary 가 단일 원천. 분할은 단순(줄바꿈/문장), 없으면 빈 처리.
"""

import re
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import MochiItem
from app.modules.mochi_items.domain.ports import MochiItemRepository
from app.modules.mochi_items.domain.value_objects import InstanceLifecycleKind
from app.modules.notifications.domain.recall_candidate import RecallCandidateRepositoryPort
from app.modules.notifications.domain.recall_feed import RecallFeedRepositoryPort
from app.shared.intent import Intent

# 표시 상수 — 소스별 kind/reason 매핑(iOS RecallReason → 색/아이콘).
_KIND_KNOWLEDGE = "knowledge"
_KIND_RECALL = "recall"
_REASON_FADING_VALUE = "fadingValue"  # spaced = "잊기 전에 한 번"
_REASON_LINKED = "linkedToRecent"  # recall = "지금 맥락과 이어져요"(트랙 C)
# gist bullet 상한 — 상세 화면 "모찌가 정리한 핵심"이 과하게 길어지지 않게(개인 사용 규모 충분).
_MAX_GIST = 5
# related(관련 기억) 조회 — ANN 이웃 상한·임계(과하게 길지 않게, 개인 규모 충분).
_DEFAULT_RELATED_MIN_SCORE = 0.5
_DEFAULT_RELATED_LIMIT = 3
# spaced 회수가 떠올리는 "잊혀가는" knowledge lifecycle. active 는 제외한다 — 사용자가
# (저장 직후거나, 회수를 열어 소생시켜) 지금 활발히 보는 중이라 회수 대상이 아니다. 이 제외가
# "opened → instance active 소생"(§5.4)과 "다음 feed 에서 빠짐"을 잇는 고리다(소생=다시 안 보여줌).
# archived 도 당연히 제외(사용자가 이미 닫음).
_RECALLABLE_SPACED_KINDS = frozenset(
    {
        InstanceLifecycleKind.DECAYING,
        InstanceLifecycleKind.REVIEW_REQUESTED,
    }
)


@dataclass(frozen=True, slots=True)
class RelatedRecallItem:
    """관련 기억 1건(트랙 C 상세 "관련 N개") — 탭 시 그 항목 상세로 가도록 item_id 운반."""

    item_id: UUID
    title: str
    oneline: str


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
    related: list[RelatedRecallItem]  # 트랙 C recall 만 채움(spaced 는 [])
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


def _is_recallable_spaced_knowledge(item: MochiItem) -> bool:
    return any(
        inst.intent_type is Intent.KNOWLEDGE
        and inst.lifecycle.kind in _RECALLABLE_SPACED_KINDS
        for inst in item.intent_instances
    )


def _to_entry(
    item: MochiItem,
    *,
    recall_event_id: UUID | None,
    kind: str,
    reason: str,
    related: list[RelatedRecallItem],
) -> RecallFeedEntry:
    oneline, gist = _split_summary(item.summary)
    return RecallFeedEntry(
        item_id=item.id,
        kind=kind,
        reason=reason,
        title=item.display_title or "",
        oneline=oneline,
        source=item.source.channel.value,
        saved_at=item.source.captured_at,
        gist=gist,
        related=related,
        # spaced 는 단건(1). recall 은 관련 N개(없으면 0 → iOS 가 섹션 숨김).
        related_count=len(related) if kind == _KIND_RECALL else 1,
        recall_event_id=recall_event_id,
    )


async def _build_related(
    *,
    candidates: RecallCandidateRepositoryPort | None,
    mochi_items: MochiItemRepository,
    owner_id: UUID,
    source_item_id: UUID,
    min_score: float,
    limit: int,
) -> list[RelatedRecallItem]:
    """앵커 item 의 ANN 이웃(관련 기억). 캐시 안 함 — 조회 시점 재실행(항상 최신). 삭제 이웃 제외."""
    if candidates is None:
        return []
    neighbors = await candidates.find_similar(
        owner_id=owner_id, source_item_id=source_item_id, min_score=min_score, limit=limit
    )
    out: list[RelatedRecallItem] = []
    for n in neighbors:
        rel = await mochi_items.find_by_id(owner_id=owner_id, mochi_item_id=n.item_id)
        if rel is None:
            continue
        oneline, _ = _split_summary(rel.summary)
        out.append(
            RelatedRecallItem(item_id=n.item_id, title=rel.display_title or "", oneline=oneline)
        )
    return out


@dataclass(slots=True)
class GetRecallFeed:
    """홈 회수 한 칸 + 자세히 목록 — 트랙 A(spaced) + 트랙 C(recall) 합류 entry."""

    feed: RecallFeedRepositoryPort
    mochi_items: MochiItemRepository
    candidates: RecallCandidateRepositoryPort | None = None
    related_min_score: float = _DEFAULT_RELATED_MIN_SCORE
    related_limit: int = _DEFAULT_RELATED_LIMIT

    async def execute(self, *, owner_id: UUID, limit: int) -> list[RecallFeedEntry]:
        cands = await self.feed.list_candidates(owner_id=owner_id, limit=limit)
        entries: list[RecallFeedEntry] = []
        for cand in cands:
            item = await self.mochi_items.find_by_id(
                owner_id=owner_id, mochi_item_id=cand.item_id
            )
            if item is None:  # 삭제됨(soft-delete) → 제외.
                continue
            if cand.source_kind == _KIND_RECALL:
                related = await _build_related(
                    candidates=self.candidates, mochi_items=self.mochi_items,
                    owner_id=owner_id, source_item_id=item.id,
                    min_score=self.related_min_score, limit=self.related_limit,
                )
                entries.append(
                    _to_entry(item, recall_event_id=cand.recall_event_id,
                              kind=_KIND_RECALL, reason=_REASON_LINKED, related=related)
                )
            else:
                # spaced — "잊혀가는"(decaying/reviewRequested) knowledge 만. active(소생/활발)·
                # archived·비-knowledge 는 제외. opened 로 소생된 항목이 여기서 자동으로 빠진다.
                if not _is_recallable_spaced_knowledge(item):
                    continue
                entries.append(
                    _to_entry(item, recall_event_id=cand.recall_event_id,
                              kind=_KIND_KNOWLEDGE, reason=_REASON_FADING_VALUE, related=[])
                )
        return entries


@dataclass(slots=True)
class GetRecallLanding:
    """알림 landing fallback — recallEventID 로 단건 entry(iOS 로컬 역매핑 실패 시 서버 fetch).

    reaction(sent 제한)과 달리 조회는 status 무관 — sent 후 탭이라도 보여야 한다. owner 스코프는 필수.
    landing 은 단건 표시라 live-knowledge 필터를 걸지 않는다(탭한 그 항목을 보여준다). 삭제·미실재면 404.
    outbox kind 로 섹션을 정한다 — recall 이면 관련 N개, 그 외는 지식 gist.
    """

    feed: RecallFeedRepositoryPort
    mochi_items: MochiItemRepository
    candidates: RecallCandidateRepositoryPort | None = None
    related_min_score: float = _DEFAULT_RELATED_MIN_SCORE
    related_limit: int = _DEFAULT_RELATED_LIMIT

    async def execute(self, *, owner_id: UUID, event_id: UUID) -> RecallFeedEntry:
        target = await self.feed.resolve_landing(owner_id=owner_id, event_id=event_id)
        if target is None:
            raise NotFoundError("Recall event not found", code="recall_event.not_found")
        item_id, outbox_kind = target
        item = await self.mochi_items.find_by_id(owner_id=owner_id, mochi_item_id=item_id)
        if item is None:
            raise NotFoundError("Recall event not found", code="recall_event.not_found")
        if outbox_kind == _KIND_RECALL:
            related = await _build_related(
                candidates=self.candidates, mochi_items=self.mochi_items,
                owner_id=owner_id, source_item_id=item_id,
                min_score=self.related_min_score, limit=self.related_limit,
            )
            return _to_entry(item, recall_event_id=event_id,
                             kind=_KIND_RECALL, reason=_REASON_LINKED, related=related)
        return _to_entry(item, recall_event_id=event_id,
                         kind=_KIND_KNOWLEDGE, reason=_REASON_FADING_VALUE, related=[])
