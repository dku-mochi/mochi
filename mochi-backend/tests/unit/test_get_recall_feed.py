"""GetRecallFeed / GetRecallLanding 단위테스트 (P5b) — 후보 하이드레이션·필터·summary 분할·landing 404.

DB 통합 fixture 없이 repository 스텁으로 application 의 필터·매핑만 본다. 후보 SELECT 의 실제 SQL
가드(active spaced·owner 스코프·deleted_at)는 PostgresRecallFeedRepository 코드 리뷰가 담당
(test_record_recall_reaction 와 동일 컨벤션). camelCase alias 는 RecallFeedEntry 스키마로 검증.
"""

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.error_envelope import NotFoundError
from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    LifecycleState,
    LifecycleStateKind,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import (
    InstanceLifecycleKind,
    InstanceLifecycleState,
    IntentInstance,
    IntentPayload,
)
from app.modules.notifications.application.get_recall_feed import (
    GetRecallFeed,
    GetRecallLanding,
    _split_summary,
)
from app.modules.notifications.domain.recall_candidate import RecallCandidate
from app.modules.notifications.domain.recall_feed import RecallFeedCandidate
from app.modules.notifications.presentation.schemas import RecallFeedEntry
from app.shared.intent import Intent

_OWNER = uuid4()


class _FeedRepo:
    """list_candidates / resolve_landing 스텁(고정 반환)."""

    def __init__(
        self,
        *,
        candidates: list[RecallFeedCandidate] | None = None,
        landing_item_id=None,  # type: ignore[no-untyped-def]
        landing_kind: str = "spaced",
    ) -> None:
        self._candidates = candidates or []
        self._landing_item_id = landing_item_id
        self._landing_kind = landing_kind

    async def list_candidates(self, *, owner_id, limit):  # type: ignore[no-untyped-def]
        return self._candidates[:limit]

    async def resolve_landing(self, *, owner_id, event_id):  # type: ignore[no-untyped-def]
        if self._landing_item_id is None:
            return None
        return self._landing_item_id, self._landing_kind


class _MochiRepo:
    """find_by_id 만 — id→item 매핑(없으면 None=삭제). 다른 메서드는 미사용."""

    def __init__(self, items: dict) -> None:  # type: ignore[type-arg]
        self._items = items

    async def find_by_id(self, *, owner_id, mochi_item_id):  # type: ignore[no-untyped-def]
        return self._items.get(mochi_item_id)


class _CandidatesRepo:
    """find_similar 만 — 고정 ANN 이웃 반환(related 채움 테스트용)."""

    def __init__(self, neighbors: list[RecallCandidate] | None = None) -> None:
        self._neighbors = neighbors or []

    async def find_similar(self, *, owner_id, source_item_id, min_score, limit):  # type: ignore[no-untyped-def]
        return self._neighbors[:limit]


def _knowledge_item(
    *,
    title: str = "Hybrid 검색",
    summary: str | None = "BM25와 벡터를 합친다. rerank로 상위만 남긴다.",
    lifecycle: InstanceLifecycleKind = InstanceLifecycleKind.DECAYING,
    intent: Intent = Intent.KNOWLEDGE,
) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(
            channel=IngestChannel.SAFARI,
            captured_at=datetime(2026, 5, 1, tzinfo=UTC),
        ),
        intent_instances=(
            IntentInstance(
                intent_type=intent,
                payload=IntentPayload(title=title),
                lifecycle=InstanceLifecycleState(kind=lifecycle),
            ),
        ),
        summary=summary,
        lifecycle=LifecycleState(kind=LifecycleStateKind.ANALYZED),
    )


# ---------- summary 분할 (oneline / gist) ----------


def test_split_summary_multiline() -> None:
    oneline, gist = _split_summary("첫 줄 핵심\n둘째 줄\n셋째 줄")
    assert oneline == "첫 줄 핵심"
    assert gist == ["첫 줄 핵심", "둘째 줄", "셋째 줄"]


def test_split_summary_sentences() -> None:
    oneline, gist = _split_summary("BM25와 벡터를 합친다. rerank로 상위만 남긴다.")
    assert oneline == "BM25와 벡터를 합친다."
    assert gist == ["BM25와 벡터를 합친다.", "rerank로 상위만 남긴다."]


def test_split_summary_empty() -> None:
    assert _split_summary(None) == ("", [])
    assert _split_summary("   ") == ("", [])


# ---------- feed 필터: "잊혀가는"(decaying/reviewRequested) spaced knowledge 만 ----------


async def test_feed_returns_knowledge_entry() -> None:
    item = _knowledge_item()
    event_id = uuid4()
    feed = _FeedRepo(
        candidates=[RecallFeedCandidate(item_id=item.id, recall_event_id=event_id)]
    )
    mochi = _MochiRepo({item.id: item})
    entries = await GetRecallFeed(feed=feed, mochi_items=mochi).execute(
        owner_id=_OWNER, limit=20
    )
    assert len(entries) == 1
    e = entries[0]
    assert e.item_id == item.id
    assert e.kind == "knowledge"
    assert e.reason == "fadingValue"
    assert e.title == "Hybrid 검색"
    assert e.oneline == "BM25와 벡터를 합친다."
    assert e.source == "safari"
    assert e.related == []
    assert e.related_count == 1
    assert e.recall_event_id == event_id


async def test_feed_excludes_deleted_item() -> None:
    # 후보는 있으나 find_by_id None(soft-deleted) → 피드에서 제외.
    deleted_id = uuid4()
    feed = _FeedRepo(
        candidates=[RecallFeedCandidate(item_id=deleted_id, recall_event_id=None)]
    )
    entries = await GetRecallFeed(feed=feed, mochi_items=_MochiRepo({})).execute(
        owner_id=_OWNER, limit=20
    )
    assert entries == []


async def test_feed_excludes_archived_knowledge() -> None:
    # knowledge 이나 archived(사용자가 닫음) → 제외.
    item = _knowledge_item(lifecycle=InstanceLifecycleKind.ARCHIVED)
    feed = _FeedRepo(
        candidates=[RecallFeedCandidate(item_id=item.id, recall_event_id=None)]
    )
    entries = await GetRecallFeed(feed=feed, mochi_items=_MochiRepo({item.id: item})).execute(
        owner_id=_OWNER, limit=20
    )
    assert entries == []


async def test_feed_excludes_active_knowledge() -> None:
    # opened 로 소생된(active) knowledge → 더는 "잊혀가는" 게 아니므로 회수 feed 에서 제외.
    # 이게 빠지지 않으면 "열어봐도 같은 항목이 계속 뜨는" 버그가 재발한다(§5.4 소생=feed 제외).
    item = _knowledge_item(lifecycle=InstanceLifecycleKind.ACTIVE)
    feed = _FeedRepo(
        candidates=[RecallFeedCandidate(item_id=item.id, recall_event_id=None)]
    )
    entries = await GetRecallFeed(feed=feed, mochi_items=_MochiRepo({item.id: item})).execute(
        owner_id=_OWNER, limit=20
    )
    assert entries == []


async def test_feed_excludes_non_knowledge() -> None:
    # spaced 인데 source 가 todo만 — knowledge 아니면 제외.
    item = _knowledge_item(intent=Intent.TODO)
    feed = _FeedRepo(
        candidates=[RecallFeedCandidate(item_id=item.id, recall_event_id=None)]
    )
    entries = await GetRecallFeed(feed=feed, mochi_items=_MochiRepo({item.id: item})).execute(
        owner_id=_OWNER, limit=20
    )
    assert entries == []


async def test_feed_empty_when_no_candidates() -> None:
    entries = await GetRecallFeed(feed=_FeedRepo(), mochi_items=_MochiRepo({})).execute(
        owner_id=_OWNER, limit=20
    )
    assert entries == []


# ---------- 트랙 C(recall): kind/reason 분기 + related 채움 ----------


async def test_feed_recall_entry_populates_related() -> None:
    # source_kind="recall" → kind="recall"/reason="linkedToRecent", related 는 ANN 이웃으로 채움.
    anchor = _knowledge_item(title="무선 마우스 A")
    related_item = _knowledge_item(title="무선 마우스 B", summary="저소음 비교 메모")
    event_id = uuid4()
    feed = _FeedRepo(
        candidates=[
            RecallFeedCandidate(
                item_id=anchor.id, recall_event_id=event_id, source_kind="recall"
            )
        ]
    )
    cand_repo = _CandidatesRepo(
        neighbors=[
            RecallCandidate(
                item_id=related_item.id, score=0.82,
                summary=related_item.summary, category=None, channel=None,
            )
        ]
    )
    entries = await GetRecallFeed(
        feed=feed,
        mochi_items=_MochiRepo({anchor.id: anchor, related_item.id: related_item}),
        candidates=cand_repo,
    ).execute(owner_id=_OWNER, limit=20)
    assert len(entries) == 1
    e = entries[0]
    assert e.kind == "recall"
    assert e.reason == "linkedToRecent"
    assert e.recall_event_id == event_id
    assert e.related_count == 1
    assert e.related[0].item_id == related_item.id
    assert e.related[0].title == "무선 마우스 B"


async def test_feed_recall_entry_not_knowledge_filtered() -> None:
    # recall 은 kind 무관 — todo-only item 도(spaced 와 달리) live-knowledge 필터에 안 걸린다.
    anchor = _knowledge_item(title="todo 캡처", intent=Intent.TODO)
    feed = _FeedRepo(
        candidates=[
            RecallFeedCandidate(item_id=anchor.id, recall_event_id=uuid4(), source_kind="recall")
        ]
    )
    entries = await GetRecallFeed(
        feed=feed, mochi_items=_MochiRepo({anchor.id: anchor}), candidates=_CandidatesRepo()
    ).execute(owner_id=_OWNER, limit=20)
    assert len(entries) == 1
    assert entries[0].kind == "recall"
    assert entries[0].related == []  # 이웃 없음 → 빈 관련


async def test_landing_recall_populates_related() -> None:
    anchor = _knowledge_item(title="무선 마우스 A")
    related_item = _knowledge_item(title="무선 마우스 B", summary="저소음 비교 메모")
    feed = _FeedRepo(landing_item_id=anchor.id, landing_kind="recall")
    cand_repo = _CandidatesRepo(
        neighbors=[
            RecallCandidate(
                item_id=related_item.id, score=0.82, summary="저소음 비교 메모",
                category=None, channel=None,
            )
        ]
    )
    entry = await GetRecallLanding(
        feed=feed,
        mochi_items=_MochiRepo({anchor.id: anchor, related_item.id: related_item}),
        candidates=cand_repo,
    ).execute(owner_id=_OWNER, event_id=uuid4())
    assert entry.kind == "recall"
    assert entry.reason == "linkedToRecent"
    assert entry.related[0].item_id == related_item.id


# ---------- landing: event → entry / 404 ----------


async def test_landing_maps_event_to_entry() -> None:
    item = _knowledge_item()
    event_id = uuid4()
    feed = _FeedRepo(landing_item_id=item.id)
    entry = await GetRecallLanding(feed=feed, mochi_items=_MochiRepo({item.id: item})).execute(
        owner_id=_OWNER, event_id=event_id
    )
    assert entry.item_id == item.id
    assert entry.recall_event_id == event_id
    assert entry.title == "Hybrid 검색"


async def test_landing_unknown_event_404() -> None:
    # resolve_landing None(남의 event·미실재) → 404.
    feed = _FeedRepo(landing_item_id=None)
    with pytest.raises(NotFoundError):
        await GetRecallLanding(feed=feed, mochi_items=_MochiRepo({})).execute(
            owner_id=_OWNER, event_id=uuid4()
        )


async def test_landing_deleted_item_404() -> None:
    # event 는 풀리나 item 이 삭제됨(find_by_id None) → 404.
    missing_id = uuid4()
    feed = _FeedRepo(landing_item_id=missing_id)
    with pytest.raises(NotFoundError):
        await GetRecallLanding(feed=feed, mochi_items=_MochiRepo({})).execute(
            owner_id=_OWNER, event_id=uuid4()
        )


# ---------- DTO camelCase alias ----------


def test_recall_feed_entry_camelcase_serialization() -> None:
    event_id = uuid4()
    item_id = uuid4()
    entry = RecallFeedEntry(
        item_id=item_id,
        kind="knowledge",
        reason="fadingValue",
        title="t",
        oneline="o",
        source="safari",
        saved_at=datetime(2026, 5, 1, tzinfo=UTC),
        gist=["a", "b"],
        related=[],
        related_count=1,
        recall_event_id=event_id,
    )
    dumped = entry.model_dump(by_alias=True, mode="json")
    assert dumped["itemId"] == str(item_id)
    assert dumped["savedAt"] == "2026-05-01T00:00:00Z"
    assert dumped["relatedCount"] == 1
    assert dumped["recallEventID"] == str(event_id)
    assert dumped["gist"] == ["a", "b"]
    assert dumped["related"] == []
