"""place entity → 도메인 → API 응답 노출 단위테스트.

분석이 entities 에 {kind:"place", value:<JSON>} 을 남기면(searchPlaceGeo), repository 매퍼가
도메인 ``MochiItem.place`` 로 끌어올리고 ``MochiItemResponse.place`` 로 노출된다 — 기록 상세의
지도 섹션이 이 값을 그린다. shopping_product/reference_url projection 과 같은 컨벤션
(ORM row 인메모리 구성, DB fixture 없음).
"""

import json
from datetime import UTC, datetime
from uuid import uuid4

from app.modules.mochi_items.domain.entities import IngestChannel, IngestSource, MochiItem, PlaceInfo
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
        row.entities.append(EntityRow(mochi_item_id=row.id, kind=kind, value=value, mochi_item=row))
    return row


def _place_json(**over: object) -> str:
    base: dict[str, object] = {
        "name": "몽탄",
        "lat": 37.5360103,
        "lng": 126.97225,
        "category": "한식>육류,고기요리",
        "address": "서울특별시 용산구 한강로1가 251-1",
        "roadAddress": "서울특별시 용산구 백범로99길 50",
        "mapUrl": "https://map.naver.com/p/search/%EB%AA%BD%ED%83%84",
    }
    base.update(over)
    return json.dumps(base, ensure_ascii=False)


def test_row_to_entity_extracts_place() -> None:
    row = _row(entities=[("deadline", "2026-07-10"), ("place", _place_json())])

    place = _row_to_entity(row).place

    assert place is not None
    assert place.name == "몽탄"
    assert place.lat == 37.5360103
    assert place.lng == 126.97225
    assert place.road_address == "서울특별시 용산구 백범로99길 50"
    assert place.map_url is not None and place.map_url.startswith("https://map.naver.com/")


def test_row_to_entity_place_requires_coordinates() -> None:
    """좌표 없는/깨진 place 는 None — 지도 섹션은 좌표가 본질이라 이름만 살리는 폴백이 없다."""
    no_coords = json.dumps({"name": "몽탄"})
    string_coords = json.dumps({"name": "몽탄", "lat": "37.5", "lng": "126.9"})
    row = _row(entities=[("place", "{bad json"), ("place", no_coords), ("place", string_coords)])

    assert _row_to_entity(row).place is None


def test_row_to_entity_place_revalidates_bounds_at_projection() -> None:
    """entity value 는 LLM 이 복사한 문자열 — tool 검증을 통과했다고 믿지 않고 projection 경계에서
    한국 bounds·finite 를 재검증한다(오복사·주입 가드, codex P2). 스케일 원값(×1e7)·NaN·bool 전부 폐기."""
    unscaled = json.dumps({"name": "몽탄", "lat": 375360103, "lng": 1269722500})  # ×1e7 원값 오복사
    nan = json.dumps({"name": "몽탄", "lat": float("nan"), "lng": 126.97})
    bool_coords = json.dumps({"name": "몽탄", "lat": True, "lng": 126.97})
    overseas = json.dumps({"name": "에펠탑", "lat": 48.8584, "lng": 2.2945})  # 지역검색은 국내 전용
    row = _row(entities=[("place", unscaled), ("place", nan), ("place", bool_coords), ("place", overseas)])

    assert _row_to_entity(row).place is None


def test_row_to_entity_place_map_url_allowlist() -> None:
    """mapUrl 은 iOS 가 그대로 openURL — 네이버 지도 https 만 통과, 그 외는 None 으로 떨어뜨려
    iOS 가 장소명 검색 URL 을 재합성하게 한다(임의 URL open 표면 차단, codex P2). 장소 자체는 유지."""
    evil = _row(entities=[("place", _place_json(mapUrl="https://evil.example.com/phish"))])
    http_only = _row(entities=[("place", _place_json(mapUrl="http://map.naver.com/p/search/x"))])
    good = _row(entities=[("place", _place_json(mapUrl="https://place.naver.com/restaurant/123"))])

    assert _row_to_entity(evil).place is not None and _row_to_entity(evil).place.map_url is None
    assert _row_to_entity(http_only).place is not None and _row_to_entity(http_only).place.map_url is None
    assert _row_to_entity(good).place.map_url == "https://place.naver.com/restaurant/123"


def test_row_to_entity_takes_first_valid_place() -> None:
    row = _row(entities=[("place", "{bad json"), ("place", _place_json()), ("place", _place_json(name="둘째"))])

    place = _row_to_entity(row).place

    assert place is not None and place.name == "몽탄"  # item 당 장소는 하나 — 첫 유효 항목


def test_row_to_entity_place_optional_meta_defaults_none() -> None:
    minimal = json.dumps({"name": "몽탄", "lat": 37.5, "lng": 126.9})
    row = _row(entities=[("place", minimal)])

    place = _row_to_entity(row).place

    assert place is not None
    assert place.category is None and place.address is None
    assert place.road_address is None and place.map_url is None


def test_row_to_entity_place_rating_and_image() -> None:
    row = _row(
        entities=[
            (
                "place",
                _place_json(
                    rating=4.6,
                    ratingCount=1234,
                    imageUrl="https://lh3.googleusercontent.com/place-photos/abc",
                ),
            )
        ]
    )

    place = _row_to_entity(row).place

    assert place is not None
    assert place.rating == 4.6 and place.rating_count == 1234
    assert place.image_url == "https://lh3.googleusercontent.com/place-photos/abc"


def test_row_to_entity_place_revalidates_rating_and_image() -> None:
    """보강 필드도 LLM 복사 경로 — 범위 밖 rating·음수 리뷰수·비 googleusercontent 이미지는
    해당 필드만 None 으로 떨어뜨리고 place 는 살린다(좌표와 달리 부가정보라 카드가 지도·주소만 그린다).
    imageUrl 은 앞점 포함 suffix 비교 — evil'googleusercontent.com' 붙임 호스트도 걸러진다."""
    row = _row(
        entities=[
            (
                "place",
                _place_json(rating=6.0, ratingCount=-3, imageUrl="https://evilgoogleusercontent.com/x.jpg"),
            )
        ]
    )

    place = _row_to_entity(row).place

    assert place is not None
    assert place.rating is None and place.rating_count is None and place.image_url is None


def test_row_to_entity_place_rating_rejects_bool_string_and_http_image() -> None:
    bool_rating = _row(entities=[("place", _place_json(rating=True))])
    str_rating = _row(entities=[("place", _place_json(rating="4.5"))])
    http_image = _row(entities=[("place", _place_json(imageUrl="http://lh3.googleusercontent.com/x"))])

    assert _row_to_entity(bool_rating).place is not None
    assert _row_to_entity(bool_rating).place.rating is None
    assert _row_to_entity(str_rating).place.rating is None
    assert _row_to_entity(http_image).place.image_url is None


def test_to_response_exposes_place_with_camel_aliases() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
        place=PlaceInfo(
            name="몽탄",
            lat=37.5360103,
            lng=126.97225,
            category="한식>육류,고기요리",
            address="서울특별시 용산구 한강로1가 251-1",
            road_address="서울특별시 용산구 백범로99길 50",
            map_url="https://map.naver.com/p/search/%EB%AA%BD%ED%83%84",
        ),
    )

    dumped = _to_response(item).model_dump(by_alias=True)

    assert dumped["place"]["name"] == "몽탄"
    assert dumped["place"]["lat"] == 37.5360103
    assert dumped["place"]["roadAddress"] == "서울특별시 용산구 백범로99길 50"
    assert dumped["place"]["mapUrl"].startswith("https://map.naver.com/")


def test_to_response_exposes_rating_with_camel_aliases() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
        place=PlaceInfo(
            name="몽탄",
            lat=37.5360103,
            lng=126.97225,
            rating=4.6,
            rating_count=1234,
            image_url="https://lh3.googleusercontent.com/place-photos/abc",
        ),
    )

    dumped = _to_response(item).model_dump(by_alias=True)

    assert dumped["place"]["rating"] == 4.6
    assert dumped["place"]["ratingCount"] == 1234
    assert dumped["place"]["imageUrl"] == "https://lh3.googleusercontent.com/place-photos/abc"


def test_to_response_place_none_when_absent() -> None:
    item = MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, captured_at=datetime.now(UTC)),
    )

    assert _to_response(item).model_dump(by_alias=True)["place"] is None
