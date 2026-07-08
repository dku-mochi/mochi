"""searchPlaceGeo tool 단위테스트.

핵심 계약 둘을 회귀로 박는다:
1. 좌표 의미 — 지역검색 mapx/mapy(WGS84 × 1e7)를 (lat, lng)로 환원하고, 한국 bounds 밖
   (좌표계 드리프트·카텍 회귀)은 후보에서 버린다. 좌표 없는 후보는 이름만 살리지 않는다
   (지도 섹션은 좌표가 본질).
2. place_entity — 메인이 그대로 복사할 JSON 에 iOS 렌더 필수 키(name/lat/lng/mapUrl)가
   실리고, 빈 메타 키는 생략된다(reference_url 동형 — 키 부재 = None 폴백).
"""

import json

import pytest

from app.modules.agent.infrastructure.tools.place_geo import (
    SearchPlaceGeoInput,
    SearchPlaceGeoTool,
    _prepared_queries,
    _to_candidate,
    _wgs84,
)


def _item(**over: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "<b>몽탄</b>",
        "category": "한식>육류,고기요리",
        "address": "서울특별시 용산구 한강로1가 251-1",
        "roadAddress": "서울특별시 용산구 백범로99길 50",
        "mapx": "1269722500",  # 126.97225 (2026-07-08 라이브 실측값)
        "mapy": "375360103",  # 37.5360103
    }
    base.update(over)
    return base


def test_wgs84_converts_scaled_integers() -> None:
    assert _wgs84("1269783882", "375666103") == (37.5666103, 126.9783882)  # 서울시청 실측


def test_wgs84_rejects_out_of_korea_bounds() -> None:
    # 카텍(KATECH) 좌표가 다시 오는 드리프트 — 크기 자릿수가 달라 bounds 밖으로 떨어진다.
    assert _wgs84("311257", "552089") is None


def test_wgs84_rejects_non_numeric() -> None:
    assert _wgs84(None, "375666103") is None
    assert _wgs84("abc", "def") is None


def test_to_candidate_strips_tags_and_builds_entity() -> None:
    cand = _to_candidate(_item())
    assert cand is not None
    assert cand.name == "몽탄"  # <b> 태그 제거
    assert cand.lat == pytest.approx(37.5360103)
    assert cand.lng == pytest.approx(126.97225)

    entity = json.loads(cand.place_entity)
    assert entity["name"] == "몽탄"
    assert entity["lat"] == pytest.approx(37.5360103)
    assert entity["lng"] == pytest.approx(126.97225)
    assert entity["mapUrl"].startswith("https://map.naver.com/p/search/")
    assert entity["roadAddress"] == "서울특별시 용산구 백범로99길 50"


def test_to_candidate_omits_empty_meta_keys() -> None:
    cand = _to_candidate(_item(category="", address="", roadAddress=""))
    assert cand is not None
    entity = json.loads(cand.place_entity)
    for absent in ("category", "address", "roadAddress"):
        assert absent not in entity  # 키 부재 = iOS None 폴백 (빈 문자열 키를 만들지 않는다)


def test_to_candidate_drops_when_coords_missing() -> None:
    assert _to_candidate(_item(mapx=None, mapy=None)) is None  # 좌표 없는 장소는 후보가 아니다


def test_map_url_appends_region_for_disambiguation() -> None:
    cand = _to_candidate(_item())
    assert cand is not None
    # 동명 지점 오매칭 완화 — 도로명 주소 앞 2토큰(시·구)을 검색어에 붙인다.
    assert "%EC%9A%A9%EC%82%B0%EA%B5%AC" in cand.map_url  # "용산구"


def test_prepared_queries_dedupe_and_bound() -> None:
    # 상한 3개를 먼저 자르고(비용 bound) 그 안에서 공백 정규화 dedupe — resource_finder 동형.
    queries = _prepared_queries(["  몽탄   용산 ", "몽탄 용산", "몽탄", "네번째"])
    assert queries == ["몽탄 용산", "몽탄"]


@pytest.mark.asyncio
async def test_run_falls_back_to_next_query_variant(monkeypatch: pytest.MonkeyPatch) -> None:
    """첫 표기가 0건이면 다음 변형으로 폴백하고, 매칭된 쿼리의 후보만 반환한다."""
    calls: list[str] = []

    async def fake_search(http: object, query: str) -> list[dict[str, object]]:
        calls.append(query)
        return [] if query == "로우키성수" else [_item(title="로우키 성수점")]

    monkeypatch.setattr("app.modules.agent.infrastructure.tools.place_geo._search_local", fake_search)
    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.place_geo.get_settings",
        lambda: type("S", (), {"naver_client_id": "id", "naver_client_secret": "secret"})(),
    )

    out, usage = await SearchPlaceGeoTool().run(SearchPlaceGeoInput(queries=["로우키성수", "로우키 성수"]))

    assert calls == ["로우키성수", "로우키 성수"]
    assert out.count == 1
    assert out.candidates[0].name == "로우키 성수점"


@pytest.mark.asyncio
async def test_run_requires_both_id_and_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    """id 만 있고 secret 이 비면 명시 에러 — 전 요청 401 빈손으로 조용히 무력화되는 것을 막는다."""
    from app.modules.agent.domain.tools import ToolExecutionError

    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.place_geo.get_settings",
        lambda: type("S", (), {"naver_client_id": "id", "naver_client_secret": None})(),
    )

    with pytest.raises(ToolExecutionError):
        await SearchPlaceGeoTool().run(SearchPlaceGeoInput(queries=["몽탄"]))


@pytest.mark.asyncio
async def test_run_returns_empty_with_guidance_when_no_match(monkeypatch: pytest.MonkeyPatch) -> None:
    """0건이면 빈손 + '좌표를 만들어내지 말라' 안내 — 좌표 발명 금지 계약."""

    async def fake_search(http: object, query: str) -> list[dict[str, object]]:
        return []

    monkeypatch.setattr("app.modules.agent.infrastructure.tools.place_geo._search_local", fake_search)
    monkeypatch.setattr(
        "app.modules.agent.infrastructure.tools.place_geo.get_settings",
        lambda: type("S", (), {"naver_client_id": "id", "naver_client_secret": "secret"})(),
    )

    out, _ = await SearchPlaceGeoTool().run(SearchPlaceGeoInput(queries=["없는가게"]))

    assert out.count == 0 and out.candidates == []
    assert "만들어내지" in out.comment
