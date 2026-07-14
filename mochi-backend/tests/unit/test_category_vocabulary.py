"""저장 시 전체기간 카테고리 어휘 조회의 owner scope·정렬 계약."""

from uuid import uuid4

from sqlalchemy.dialects import postgresql

from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository


class _FakeScalars:
    def all(self) -> list[str]:
        return [" 쇼핑 ", "투자", ""]


class _FakeSession:
    def __init__(self) -> None:
        self.statement = None

    async def scalars(self, statement):  # type: ignore[no-untyped-def]
        self.statement = statement
        return _FakeScalars()


async def test_category_vocabulary_is_owner_scoped_and_ranked() -> None:
    owner_id = uuid4()
    session = _FakeSession()
    repo = PostgresMochiItemRepository(session)  # type: ignore[arg-type]

    labels = await repo.list_category_vocabulary(owner_id=owner_id, limit=50)

    assert labels == ["쇼핑", "투자"]
    assert session.statement is not None
    sql = str(session.statement.compile(dialect=postgresql.dialect()))
    assert "mochi_items.owner_id =" in sql
    assert "mochi_items.deleted_at IS NULL" in sql
    assert "CASE WHEN (count(mochi_items.category_normalized_at) >" in sql
    assert sql.index("CASE WHEN") < sql.index("count(mochi_items.id) DESC")
    assert "LIMIT" in sql
