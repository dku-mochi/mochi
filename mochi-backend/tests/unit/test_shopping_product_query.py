"""shopping_product entity → 도메인 → API 응답 노출 단위 테스트.

분석이 entities 에 {kind:"shopping_product", value:<검색어>} 를 남기면(lab
shopping-product-link exp1), repository 매퍼가 도메인 ``shopping_product_query`` 로
끌어올리고 ``MochiItemResponse.shoppingProductQuery`` 로 노출된다 — 카드 상세의
커머스 "검색된 상태" 링크가 이 값을 쓴다. DB 통합 fixture 가 없어 ORM row 를
인메모리로 구성한다 (기존 단위테스트 컨벤션).
"""

from datetime import UTC, datetime
from uuid import uuid4

from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    MochiItem,
)
from app.modules.mochi_items.infrastructure.orm import EntityRow, MochiItemRow
from app.modules.mochi_items.infrastructure.repository import _row_to_entity
from app.modules.mochi_items.presentation.router import _to_response


def _row(*, entities: list[tuple[str, str]]) -> MochiItemRow:
    row = MochiItemRow(
        owner_id=uuid4(),
        channel=IngestChannel.SCREENSHOT.value,
        url=None,
        text=None,
        user_memo=None,
        captured_at=datetime.now(UTC),
    )
    row.id = uuid4()
    for kind, value in entities:
        row.entities.append(
            EntityRow(mochi_item_id=row.id, kind=kind, value=value, mochi_item=row)
        )
    return row


def test_row_to_entity_extracts_shopping_product_query() -> None:
    row = _row(
        entities=[
            ("deadline", "2026-06-30"),
            ("shopping_product", "로지텍 MX Master 3S 펄화이트"),
        ]
    )
    item = _row_to_entity(row)
    assert item.shopping_product_query == "로지텍 MX Master 3S 펄화이트"


def test_row_to_entity_without_shopping_entity_is_none() -> None:
    row = _row(entities=[("deadline", "2026-06-30")])
    assert _row_to_entity(row).shopping_product_query is None


def test_to_response_exposes_camel_case_alias() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
        shopping_product_query="나이키 페가수스 41",
    )
    response = _to_response(item)
    assert response.shopping_product_query == "나이키 페가수스 41"
    assert response.model_dump(by_alias=True)["shoppingProductQuery"] == "나이키 페가수스 41"
