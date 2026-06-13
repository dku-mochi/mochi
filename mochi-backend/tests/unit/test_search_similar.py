"""PostgresHybridIndex.similar 검증 — fake 세션으로 SQL·바인드와 reasons 파생을 캡처한다.

similar 는 "비슷한 기록"(상세 화면, DOMAIN_DESIGN §10.5)을 위한 seed-vector 이웃 조회다.
실DB 없이 단위로 검증하는 항목 — (a) 자기 제외·owner-scope SQL 구조, (b) 임계값/fanout 바인드,
(c) 같은 출처 URL dedup, (d) reasons(sharedSource/sameIntent/closeInTime) 파생, (e) 대상에
embedding 이 없을 때(메인 쿼리 0행) 빈 배열 degrade — 두 번째 intent 쿼리도 생략.
"""

from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.modules.search.domain.entities import SimilarReasonKind
from app.modules.search.infrastructure.postgres_index import PostgresHybridIndex

pytestmark = pytest.mark.anyio

_NOW = datetime(2026, 6, 13, tzinfo=UTC)


async def _noop_embed(_: str) -> list[float] | None:
    return None


class _FakeResult:
    def __init__(self, rows: list) -> None:
        self._rows = rows

    def all(self) -> list:
        return self._rows


class _FakeSession:
    """execute 순서대로 미리 준비한 결과를 돌려주고, 호출된 SQL 을 캡처한다."""

    def __init__(self, results: list[list]) -> None:
        self._results = list(results)
        self.captured: list = []

    async def execute(self, sql, params=None):  # noqa: ANN001
        self.captured.append(sql)
        rows = self._results.pop(0) if self._results else []
        return _FakeResult(rows)


def _index(results: list[list]) -> PostgresHybridIndex:
    return PostgresHybridIndex(_FakeSession(results), query_embedding_provider=_noop_embed)


async def test_similar_query_is_owner_scoped_and_excludes_self() -> None:
    sess = _FakeSession([[], []])
    index = PostgresHybridIndex(sess, query_embedding_provider=_noop_embed)
    target, owner = uuid4(), uuid4()

    await index.similar(owner_id=owner, mochi_item_id=target, limit=6, min_score=0.6)

    sql = str(sess.captured[0])
    assert "owner_id = :owner_id" in sql
    assert "c.id <> :target_id" in sql
    assert "deleted_at IS NULL" in sql
    binds = sess.captured[0]._bindparams
    assert binds["target_id"].value == target
    assert binds["owner_id"].value == owner
    assert binds["min_score"].value == 0.6
    assert binds["fanout"].value == 24  # limit(6) * _SIMILAR_CANDIDATE_FANOUT(4)


async def test_similar_empty_when_target_has_no_embedding() -> None:
    # 메인 쿼리 0행 = 대상에 embedding 없음(미색인·VOYAGE 미설정) → 빈 배열, intent 쿼리 미실행.
    index = _index([[]])
    items = await index.similar(owner_id=uuid4(), mochi_item_id=uuid4(), limit=6, min_score=0.6)
    assert items == []


async def test_similar_derives_reasons() -> None:
    target, owner = uuid4(), uuid4()
    near, far = uuid4(), uuid4()
    main_rows = [
        SimpleNamespace(
            mochi_item_id=near, score=0.92, url="https://toss.im/a",
            captured_at=_NOW, target_url="https://toss.im/a", target_captured_at=_NOW,
        ),
        SimpleNamespace(
            mochi_item_id=far, score=0.71, url=None,
            captured_at=_NOW - timedelta(days=10), target_url="https://toss.im/a", target_captured_at=_NOW,
        ),
    ]
    intent_rows = [
        SimpleNamespace(mochi_item_id=target, intent_type="todo"),
        SimpleNamespace(mochi_item_id=near, intent_type="todo"),
        SimpleNamespace(mochi_item_id=far, intent_type="memo"),
    ]
    items = await _index([main_rows, intent_rows]).similar(
        owner_id=owner, mochi_item_id=target, limit=6, min_score=0.6
    )

    assert [i.mochi_item_id for i in items] == [near, far]
    assert {r.kind for r in items[0].reasons} == {
        SimilarReasonKind.SHARED_SOURCE,
        SimilarReasonKind.SAME_INTENT,
        SimilarReasonKind.CLOSE_IN_TIME,
    }
    same_intent = next(r for r in items[0].reasons if r.kind is SimilarReasonKind.SAME_INTENT)
    assert same_intent.value == "todo"
    # far: url None(공유 출처 X) · intent memo≠todo(같은 의도 X) · 10일 차이(근접 X) → 근거 없음
    assert items[1].reasons == []


async def test_similar_dedups_same_source_url() -> None:
    target, owner = uuid4(), uuid4()
    first, dup, other = uuid4(), uuid4(), uuid4()
    main_rows = [
        SimpleNamespace(mochi_item_id=first, score=0.90, url="https://x.com/p",
                        captured_at=_NOW, target_url=None, target_captured_at=_NOW),
        SimpleNamespace(mochi_item_id=dup, score=0.85, url="https://x.com/p",
                        captured_at=_NOW, target_url=None, target_captured_at=_NOW),
        SimpleNamespace(mochi_item_id=other, score=0.80, url="https://y.com",
                        captured_at=_NOW, target_url=None, target_captured_at=_NOW),
    ]
    items = await _index([main_rows, []]).similar(
        owner_id=owner, mochi_item_id=target, limit=6, min_score=0.6
    )
    # 같은 https://x.com/p 두 건 중 더 유사한 first 만 남고 dup 은 접힌다.
    assert [i.mochi_item_id for i in items] == [first, other]
