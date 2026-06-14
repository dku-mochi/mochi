"""shopping_product entity → 도메인 → API 응답 노출 단위 테스트.

분석이 entities 에 {kind:"shopping_product", value:<검색어>} 를 남기면(lab
shopping-product-link exp1), repository 매퍼가 도메인 ``shopping_product_query`` 로
끌어올리고 ``MochiItemResponse.shoppingProductQuery`` 로 노출된다 — 카드 상세의
커머스 "검색된 상태" 링크가 이 값을 쓴다. DB 통합 fixture 가 없어 ORM row 를
인메모리로 구성한다 (기존 단위테스트 컨벤션).
"""

import json
from datetime import UTC, datetime
from uuid import uuid4

from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    MochiItem,
    ReferenceLink,
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


def test_row_to_entity_extracts_reference_links_from_json_entities() -> None:
    value = json.dumps(
        {
            "url": "https://map.naver.com/p/search/%EB%AA%BD%ED%83%84",
            "title": "몽탄 - 네이버 지도 검색",
            "label": "네이버 지도에서 보기",
            "role": "reserve",
            "provider": "naver_map",
            "rankProfile": "local",
            "source": "synthetic:naver_map",
            "usefulness": 5,
        },
        ensure_ascii=False,
    )
    row = _row(entities=[("reference_url", value), ("reference_url", "{bad json")])

    item = _row_to_entity(row)

    assert len(item.reference_links) == 1
    link = item.reference_links[0]
    assert link.label == "네이버 지도에서 보기"
    assert link.provider == "naver_map"
    assert link.rank_profile == "local"


def test_row_to_entity_keeps_plain_url_reference() -> None:
    """메인이 JSON 대신 URL 문자열만 저장해도(flash-lite 불준수 관측) 링크가 사라지지 않는다 —
    기본 메타로 살리되 usefulness 는 None(뱃지 OFF). 비-URL 잡값은 여전히 버린다."""
    row = _row(
        entities=[
            ("reference_url", "https://soco.seoul.go.kr/youth/pgm/home/yohome/view.do?homeCode=2"),
            ("reference_url", "그냥 텍스트"),
        ]
    )

    item = _row_to_entity(row)

    assert len(item.reference_links) == 1
    link = item.reference_links[0]
    assert link.url.startswith("https://soco.seoul.go.kr")
    assert link.label == "관련 링크 열기"   # 기본값
    assert link.provider == "unknown"
    assert link.usefulness is None          # 뱃지 OFF


def test_to_response_exposes_reference_links_alias() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
        reference_links=(
            ReferenceLink(
                url="https://app.catchtable.co.kr/ct/shop/mongtan",
                title="몽탄 - 캐치테이블",
                label="캐치테이블에서 예약",
                role="reserve",
                provider="catchtable",
                rank_profile="local",
                source="naver:local",
                usefulness=5,
            ),
        ),
    )

    response = _to_response(item)
    dumped = response.model_dump(by_alias=True)

    assert dumped["referenceLinks"][0]["label"] == "캐치테이블에서 예약"
    assert dumped["referenceLinks"][0]["rankProfile"] == "local"


def test_row_to_entity_extracts_reference_metadata() -> None:
    """subtitle·priceText 가 있으면 도메인으로 복원, 없는 구 JSON 은 None(하위호환)."""
    with_meta = json.dumps(
        {"url": "https://www.oliveyoung.co.kr/goods/1", "title": "토리든 세럼",
         "label": "올리브영에서 보기", "role": "buy", "provider": "oliveyoung",
         "rankProfile": "cosmetics", "subtitle": "토리든", "priceText": "18,900원"},
        ensure_ascii=False,
    )
    legacy = json.dumps(
        {"url": "https://blog.naver.com/x", "title": "후기", "label": "관련 글 보기",
         "role": "read", "provider": "info", "rankProfile": "general"},
        ensure_ascii=False,
    )
    row = _row(entities=[("reference_url", with_meta), ("reference_url", legacy)])

    links = _row_to_entity(row).reference_links

    assert len(links) == 2
    assert links[0].subtitle == "토리든"
    assert links[0].price_text == "18,900원"
    assert links[1].subtitle is None    # 구 데이터·메타없는 링크 하위호환
    assert links[1].price_text is None


def test_to_response_exposes_reference_metadata_alias() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
        reference_links=(
            ReferenceLink(
                url="https://www.oliveyoung.co.kr/goods/1",
                title="토리든 세럼",
                label="올리브영에서 보기",
                role="buy",
                provider="oliveyoung",
                rank_profile="cosmetics",
                subtitle="토리든",
                price_text="18,900원",
            ),
        ),
    )

    dumped = _to_response(item).model_dump(by_alias=True)

    assert dumped["referenceLinks"][0]["subtitle"] == "토리든"
    assert dumped["referenceLinks"][0]["priceText"] == "18,900원"
