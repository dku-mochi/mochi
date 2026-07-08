"""searchPlaceGeo — 캡처가 가리킨 장소의 좌표·주소를 키워드 검색으로 회수하는 tool.

기록 상세의 지도 섹션(iOS Map + 네이버 길찾기)이 좌표를 그리려면 분석 시점에 장소를
지오코딩해 둬야 한다. 백본은 네이버 지역검색 API(고정 호스트 openapi.naver.com —
findReferenceUrls 선례와 동일, 가변 URL SSRF 면 아님): 키워드 검색 한 번으로 상호·업종·
주소·좌표가 같이 온다. 별도 지오코딩 API(NCP Maps) 키를 늘리지 않는다.

좌표 의미: 지역검색 mapx/mapy 는 WGS84 경도/위도 × 1e7 정수 문자열이다
(2026-07-08 라이브 실측 — 서울시청 mapx=1269783882 → 126.9783882, 정확 일치).
의미가 다시 바뀌는 드리프트에 대비해 한국 bounds 밖 좌표는 후보에서 버린다.

후보 선택은 이미지를 본 메인 에이전트가 한다(findReferenceUrls 와 같은 원리 — 키워드도
대상 판단도 캡처를 보는 쪽이 정확하다). tool 은 후보별로 entities(kind='place') 에 그대로
복사할 ``place_entity`` JSON 을 완성해 준다(reference_url 패턴 동형).
"""

import json
import re
import time
from typing import Any
from urllib.parse import quote

import httpx
from pydantic import BaseModel, Field

from app.core.config import get_settings
from app.core.logging import get_logger
from app.modules.agent.domain.tools import Tool, ToolExecutionError, ToolName, ToolUsage

log = get_logger("agent.tool.place_geo")

_NAVER_LOCAL_URL = "https://openapi.naver.com/v1/search/local.json"
_DISPLAY = 5  # 지역검색 display 상한이 5
_MAX_QUERIES = 3  # 상호 표기 변형(띄어쓰기·지점명) 재시도 상한 — 비용 bound
_MAX_QUERY_LEN = 100
_TAG_RE = re.compile(r"<[^>]+>")

# 한국 좌표 bounds — 지역검색은 국내 전용이라 이 밖의 값은 좌표 의미 드리프트(카텍 회귀 등)다.
_LAT_RANGE = (33.0, 39.5)
_LNG_RANGE = (124.0, 132.0)


class SearchPlaceGeoInput(BaseModel):
    # 메인이 캡처에서 읽은 장소명 검색어. 첫 쿼리가 0건이면 다음 변형으로 폴백한다 —
    # 지역검색은 상호 띄어쓰기에 민감해 "로우키성수" / "로우키 성수" 가 갈린다.
    queries: list[str] = Field(min_length=1)


class PlaceCandidate(BaseModel):
    name: str
    category: str = ""  # 네이버 업종 경로 ("카페,디저트>카페"). 표시 가공은 클라이언트.
    address: str = ""
    road_address: str = ""
    lat: float
    lng: float
    map_url: str
    # entities(kind='place') 로 한 글자도 바꾸지 말고 복사할 JSON — reference_entities 동형.
    place_entity: str


class SearchPlaceGeoOutput(BaseModel):
    candidates: list[PlaceCandidate] = Field(default_factory=list)
    count: int = 0
    comment: str = ""


class SearchPlaceGeoTool(Tool[SearchPlaceGeoInput, SearchPlaceGeoOutput]):
    """키워드 → 장소 후보(좌표 포함). 후보가 없으면 빈손 — 좌표를 발명하지 않는다."""

    name = ToolName.SEARCH_PLACE_GEO
    input_model = SearchPlaceGeoInput
    output_model = SearchPlaceGeoOutput

    async def run(self, payload: SearchPlaceGeoInput) -> tuple[SearchPlaceGeoOutput, ToolUsage]:
        settings = get_settings()
        # secret 까지 확인 — id 만 있으면 전 요청이 401 로 빈손이 돼 조용히 무력화된다(codex P3).
        if not settings.naver_client_id or not settings.naver_client_secret:
            raise ToolExecutionError(self.name, "Naver search API key not configured")
        started = time.perf_counter()

        headers = {
            "X-Naver-Client-Id": settings.naver_client_id or "",
            "X-Naver-Client-Secret": settings.naver_client_secret or "",
        }
        candidates: list[PlaceCandidate] = []
        async with httpx.AsyncClient(headers=headers, timeout=15) as http:
            for query in _prepared_queries(payload.queries):
                items = await _search_local(http, query)
                candidates = [c for it in items if (c := _to_candidate(it)) is not None]
                if candidates:
                    # 쿼리 변형별 후보를 섞지 않는다 — 첫 매칭 쿼리의 결과가 곧 그 표기의 장소들.
                    break

        usage = ToolUsage(latency_ms=int((time.perf_counter() - started) * 1000))
        comment = (
            "캡처의 장소와 일치하는 후보의 place_entity 를 entities(kind='place')로 복사하세요."
            if candidates
            else "일치하는 장소를 찾지 못했습니다 — 좌표를 만들어내지 말고 장소 없이 마무리하세요."
        )
        return (
            SearchPlaceGeoOutput(candidates=candidates, count=len(candidates), comment=comment),
            usage,
        )


def _prepared_queries(queries: list[str]) -> list[str]:
    out: list[str] = []
    for raw in queries[:_MAX_QUERIES]:
        q = " ".join(raw.split())[:_MAX_QUERY_LEN]
        if q and q not in out:
            out.append(q)
    return out


async def _search_local(http: httpx.AsyncClient, query: str) -> list[dict[str, Any]]:
    try:
        resp = await http.get(_NAVER_LOCAL_URL, params={"query": query, "display": _DISPLAY})
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        # 한 쿼리 실패가 run 을 죽이지 않는다 — 다음 변형으로 폴백, 전부 실패면 빈손.
        log.warning("tool.place_geo.naver_failed", query=query, error=str(exc))
        return []
    items = data.get("items", [])
    return items if isinstance(items, list) else []


def _to_candidate(item: dict[str, Any]) -> PlaceCandidate | None:
    name = _strip_tags(str(item.get("title") or ""))
    coords = _wgs84(item.get("mapx"), item.get("mapy"))
    if not name or coords is None:
        return None
    lat, lng = coords
    address = str(item.get("address") or "").strip()
    road_address = str(item.get("roadAddress") or "").strip()
    category = str(item.get("category") or "").strip()
    map_url = _naver_map_url(name, road_address or address)
    entity: dict[str, Any] = {"name": name, "lat": lat, "lng": lng, "mapUrl": map_url}
    # 값 있는 키만 싣는다 — iOS 가 키 부재를 None 으로 읽어 빈 줄을 만들지 않는다(reference_url 동형).
    if category:
        entity["category"] = category
    if address:
        entity["address"] = address
    if road_address:
        entity["roadAddress"] = road_address
    return PlaceCandidate(
        name=name,
        category=category,
        address=address,
        road_address=road_address,
        lat=lat,
        lng=lng,
        map_url=map_url,
        place_entity=json.dumps(entity, ensure_ascii=False, separators=(",", ":")),
    )


def _wgs84(mapx: Any, mapy: Any) -> tuple[float, float] | None:
    """지역검색 mapx/mapy(WGS84 × 1e7 정수 문자열) → (lat, lng). 의미가 안 맞으면 None."""
    try:
        lng = int(str(mapx)) / 1e7
        lat = int(str(mapy)) / 1e7
    except (TypeError, ValueError):
        return None
    if not (_LAT_RANGE[0] <= lat <= _LAT_RANGE[1] and _LNG_RANGE[0] <= lng <= _LNG_RANGE[1]):
        return None
    return lat, lng


def _naver_map_url(name: str, address: str) -> str:
    """네이버 지도 검색 URL — 동명 지점 오매칭을 줄이려 시·구(주소 앞 2토큰)를 붙인다.

    지역검색 API 는 place id 를 주지 않아 직링크 대신 검색 URL 을 쓴다(resource_finder
    synthetic 지도링크와 동일 형태 — 이 tool 의 후보는 검색 API 실매칭이라 실존이 보장된다).
    """
    region = " ".join(address.split()[:2])
    query = f"{name} {region}".strip()
    # safe="" — 상호에 '/' 가 섞여도 path segment 하나로 통짜 인코딩(기본 safe="/" 는 경로가 갈라진다).
    return "https://map.naver.com/p/search/" + quote(query, safe="")


def _strip_tags(text: str) -> str:
    return _TAG_RE.sub("", text).strip()
