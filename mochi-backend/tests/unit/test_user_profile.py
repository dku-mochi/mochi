"""사용자 개인화 프로필 디바운스 갱신(RefreshUserProfile) 단위 테스트.

실제 LLM/DB 없이 디바운스 판정·window·upsert 만 검증.
"""

from uuid import uuid4

import pytest

from app.modules.agent.application.refresh_user_profile import RefreshUserProfile
from app.modules.agent.domain.profile import ProfileWindowItem, UserProfile
from app.shared.intent import Intent


class _FakeStore:
    def __init__(self, profile: UserProfile | None = None):
        self.profile = profile
        self.upserts: list[UserProfile] = []

    async def get(self, *, owner_id):
        return self.profile

    async def upsert(self, profile: UserProfile):
        self.upserts.append(profile)
        self.profile = profile


class _FakeSummarizer:
    def __init__(
        self,
        text="관심사: AI. 마감 있는 과제는 할 일로 분류.",
        chat_text="요즘 AI 공부와 개발에 푹 빠진 사람.",
    ):
        self.text = text
        self.chat_text = chat_text
        self.calls = 0
        self.chat_calls = 0

    async def summarize(self, *, window, previous):
        self.calls += 1
        return self.text

    async def summarize_chat(self, *, window, previous):
        self.chat_calls += 1
        return self.chat_text


class _FakeGateway:
    def __init__(self, count: int, window: list[ProfileWindowItem] | None = None):
        self._count = count
        self._window = window or []

    async def count_items(self, *, owner_id):
        return self._count

    async def list_recent_window(self, *, owner_id, limit):
        return self._window[:limit]

    async def load_source(self, *, owner_id, mochi_item_id):
        return None

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        return None


def _win(n: int) -> list[ProfileWindowItem]:
    return [
        ProfileWindowItem(
            summary=f"s{i}",
            intent_types=(Intent.TODO,),
            user_memo=None,
        )
        for i in range(n)
    ]


def _refresh(gateway, store, summarizer, every_n: int = 5) -> RefreshUserProfile:
    return RefreshUserProfile(
        gateway=gateway,
        store=store,
        summarizer=summarizer,
        window_size=20,
        refresh_every_n=every_n,
        model_version="test",
    )


@pytest.mark.asyncio
async def test_first_profile_created_when_none():
    store = _FakeStore(profile=None)
    summ = _FakeSummarizer()
    gw = _FakeGateway(count=3, window=_win(3))
    did = await _refresh(gw, store, summ).run(owner_id=uuid4())
    assert did is True
    assert summ.calls == 1
    assert store.profile is not None
    assert store.profile.items_covered == 3


@pytest.mark.asyncio
async def test_debounced_when_below_threshold():
    owner = uuid4()
    store = _FakeStore(
        profile=UserProfile(owner_id=owner, summary="old", model_version="test", items_covered=10)
    )
    summ = _FakeSummarizer()
    gw = _FakeGateway(count=12, window=_win(12))  # 12-10=2 < 5
    did = await _refresh(gw, store, summ).run(owner_id=owner)
    assert did is False
    assert summ.calls == 0


@pytest.mark.asyncio
async def test_refresh_when_threshold_reached():
    owner = uuid4()
    store = _FakeStore(
        profile=UserProfile(owner_id=owner, summary="old", model_version="test", items_covered=10)
    )
    summ = _FakeSummarizer()
    gw = _FakeGateway(count=15, window=_win(15))  # 15-10=5 >= 5
    did = await _refresh(gw, store, summ).run(owner_id=owner)
    assert did is True
    assert store.profile.items_covered == 15


@pytest.mark.asyncio
async def test_no_items_skips():
    store = _FakeStore(profile=None)
    summ = _FakeSummarizer()
    gw = _FakeGateway(count=0)
    did = await _refresh(gw, store, summ).run(owner_id=uuid4())
    assert did is False
    assert summ.calls == 0


@pytest.mark.asyncio
async def test_chat_summary_distilled_alongside_classification():
    """갱신 시 분류 프로필(summary)과 채팅 페르소나(chat_summary)가 함께 distill·upsert 된다."""
    store = _FakeStore(profile=None)
    summ = _FakeSummarizer()
    gw = _FakeGateway(count=3, window=_win(3))
    did = await _refresh(gw, store, summ).run(owner_id=uuid4())
    assert did is True
    assert summ.calls == 1
    assert summ.chat_calls == 1
    assert store.profile.summary == summ.text
    assert store.profile.chat_summary == summ.chat_text


@pytest.mark.asyncio
async def test_chat_summary_failure_keeps_classification_profile():
    """채팅 distill 이 실패해도(부가 산출물) 분류 프로필 저장은 막히지 않는다."""

    class _ChatFails(_FakeSummarizer):
        async def summarize_chat(self, *, window, previous):
            raise RuntimeError("chat distill boom")

    store = _FakeStore(profile=None)
    summ = _ChatFails()
    gw = _FakeGateway(count=3, window=_win(3))
    did = await _refresh(gw, store, summ).run(owner_id=uuid4())
    assert did is True
    assert store.profile.summary == summ.text
    assert store.profile.chat_summary is None  # 이전 값 없음 + 실패 → None
