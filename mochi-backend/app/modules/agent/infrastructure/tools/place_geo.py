"""searchPlaceGeo — 캡처가 가리킨 장소의 좌표·주소를 키워드 검색으로 회수하는 tool.

기록 상세의 지도 섹션(iOS Map + 네이버 길찾기)이 좌표를 그리려면 분석 시점에 장소를
지오코딩해 둬야 한다. 백본은 네이버 지역검색 API(고정 호스트 openapi.naver.com —
findReferenceUrls 선례와 동일, 가변 URL SSRF 면 아님): 키워드 검색 한 번으로 상호·업종·
주소·좌표가 같이 온다. 별도 지오코딩 API(NCP Maps) 키를 늘리지 않는다.

별점·매장사진 보강은 Google Places(New)가 담당한다 — 네이버·카카오는 별점 공개 API 가
없어 유일한 공식 소스다. 후보 좌표 근방 텍스트검색으로 1:1 매칭하고, 좌표 거리가 멀면
같은 가게로 인정하지 않고 보강을 포기한다(남의 가게 별점을 붙이는 것은 없는 것보다
나쁘다 — 좌표 발명 금지와 같은 원칙). 키 미설정·호출 실패는 후보 단위로 삼켜 좌표·주소
백본을 해치지 않는다.

좌표 의미: 지역검색 mapx/mapy 는 WGS84 경도/위도 × 1e7 정수 문자열이다
(2026-07-08 라이브 실측 — 서울시청 mapx=1269783882 → 126.9783882, 정확 일치).
의미가 다시 바뀌는 드리프트에 대비해 한국 bounds 밖 좌표는 후보에서 버린다.

후보 선택은 이미지를 본 메인 에이전트가 한다(findReferenceUrls 와 같은 원리 — 키워드도
대상 판단도 캡처를 보는 쪽이 정확하다). tool 은 후보별로 entities(kind='place') 에 그대로
복사할 ``place_entity`` JSON 을 완성해 준다(reference_url 패턴 동형).
"""

import asyncio
import json
import math
import re
import time
from typing import Any
from urllib.parse import quote, urlparse

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

# Google Places(New) 보강 — 고정 호스트 places.googleapis.com (가변 URL SSRF 면 아님).
_GOOGLE_SEARCH_URL = "https://places.googleapis.com/v1/places:searchText"
_GOOGLE_PHOTO_URL = "https://places.googleapis.com/v1/{name}/media"
_GOOGLE_FIELD_MASK = "places.displayName,places.rating,places.userRatingCount,places.photos,places.location"
_GOOGLE_PHOTO_MAX_WIDTH = 1000  # 카드 썸네일 용도 — 원본 해상도를 끌어오지 않는다
_GOOGLE_LOCATION_BIAS_METERS = 500.0
# 네이버 후보 좌표와 Google 결과 좌표가 이보다 멀면 다른 가게로 보고 보강을 포기한다.
_GOOGLE_MATCH_MAX_METERS = 300.0
# photo name 은 응답 유래 문자열이지만 URL path 로 들어간다 — 리소스 형식을 정규식으로 강제해
# `?`/`#`/`..`/중복 slash 로 의도 밖 path·query 가 합성되는 것을 막는다(codex P2).
_GOOGLE_PHOTO_NAME_RE = re.compile(r"^places/[^/?#]+/photos/[^/?#]+$")


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

        if candidates and settings.google_places_api_key:
            candidates = await _enrich_with_google(candidates, settings.google_places_api_key)

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


async def _enrich_with_google(candidates: list[PlaceCandidate], api_key: str) -> list[PlaceCandidate]:
    """후보별 Google Places 매칭으로 rating/ratingCount/imageUrl 을 place_entity 에 더한다.

    실패는 후보 단위로 삼킨다(_enrich_candidate) — 보강은 부가정보라 어떤 실패도
    좌표·주소 백본을 해치지 않는다. 후보는 최대 5개, 동시 실행으로 왕복 1회분 latency.
    """
    headers = {"X-Goog-Api-Key": api_key, "X-Goog-FieldMask": _GOOGLE_FIELD_MASK}
    async with httpx.AsyncClient(headers=headers, timeout=10) as http:
        return list(await asyncio.gather(*(_enrich_candidate(http, c) for c in candidates)))


async def _enrich_candidate(http: httpx.AsyncClient, cand: PlaceCandidate) -> PlaceCandidate:
    try:
        place = await _google_search_text(http, cand)
        if place is None:
            return cand
        extras: dict[str, Any] = {}
        rating = place.get("rating")
        if isinstance(rating, int | float) and not isinstance(rating, bool) and 0 <= float(rating) <= 5:
            extras["rating"] = round(float(rating), 1)
            count = place.get("userRatingCount")
            # 리뷰 수는 별점 없이는 의미가 없다 — rating 이 실릴 때만 함께 싣는다.
            if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
                extras["ratingCount"] = count
        image_url = await _first_photo_uri(http, place)
        if image_url:
            extras["imageUrl"] = image_url
        if not extras:
            return cand
        entity = json.loads(cand.place_entity)
        entity.update(extras)
        return cand.model_copy(
            update={"place_entity": json.dumps(entity, ensure_ascii=False, separators=(",", ":"))}
        )
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        log.warning("tool.place_geo.google_enrich_failed", place=cand.name, error=str(exc))
        return cand


async def _google_search_text(http: httpx.AsyncClient, cand: PlaceCandidate) -> dict[str, Any] | None:
    """네이버 후보를 Google Places 텍스트검색으로 1:1 매칭 — 좌표가 가까울 때만 같은 가게로 인정."""
    body = {
        "textQuery": f"{cand.name} {cand.road_address or cand.address}".strip(),
        "languageCode": "ko",
        "regionCode": "KR",
        "pageSize": 1,
        "locationBias": {
            "circle": {
                "center": {"latitude": cand.lat, "longitude": cand.lng},
                "radius": _GOOGLE_LOCATION_BIAS_METERS,
            }
        },
    }
    resp = await http.post(_GOOGLE_SEARCH_URL, json=body)
    resp.raise_for_status()
    places = resp.json().get("places")
    if not isinstance(places, list) or not places or not isinstance(places[0], dict):
        return None
    place: dict[str, Any] = places[0]
    location = place.get("location") or {}
    g_lat, g_lng = location.get("latitude"), location.get("longitude")
    if not isinstance(g_lat, int | float) or not isinstance(g_lng, int | float):
        return None
    # NaN 좌표는 모든 비교가 False 라 거리 게이트를 그대로 통과한다 — finite 를 강제(codex P3).
    if not math.isfinite(float(g_lat)) or not math.isfinite(float(g_lng)):
        return None
    if _haversine_m(cand.lat, cand.lng, float(g_lat), float(g_lng)) > _GOOGLE_MATCH_MAX_METERS:
        return None
    # 좌표만으론 몰·역세권의 동명·인접 매장을 못 가른다 — 상호까지 겹쳐야 같은 가게(codex P2).
    display_name = place.get("displayName") or {}
    google_name = display_name.get("text") if isinstance(display_name, dict) else None
    if not isinstance(google_name, str) or not _names_overlap(cand.name, google_name):
        return None
    return place


def _names_overlap(naver_name: str, google_name: str) -> bool:
    """공백·대소문자 정규화 후 한쪽이 다른 쪽을 포함하면 같은 상호로 본다.

    지점명 표기 차("몽탄" vs "몽탄 본점")는 포함 관계로 흡수하고, 전혀 다른 상호가
    거리 게이트만 통과하는 경우를 거른다. 언어가 갈리면(한/영) 보강을 포기한다 —
    남의 별점을 붙이느니 빈손이 낫다.
    """
    a = "".join(naver_name.split()).lower()
    b = "".join(google_name.split()).lower()
    return bool(a) and bool(b) and (a in b or b in a)


async def _first_photo_uri(http: httpx.AsyncClient, place: dict[str, Any]) -> str | None:
    """photos[0].name → 실제 이미지 URI. ``skipHttpRedirect=true`` 는 302 대신 JSON({photoUri})을 준다.

    photoUri 는 googleusercontent 호스트만 통과 — iOS 가 그대로 로드하는 URL 이라
    projection 의 mapUrl allowlist 와 같은 원칙으로 소스에서 한 번 더 좁힌다.
    """
    photos = place.get("photos")
    if not isinstance(photos, list) or not photos or not isinstance(photos[0], dict):
        return None
    photo_name = photos[0].get("name")
    # photo name 은 URL path 로 들어간다 — `places/{id}/photos/{res}` 형식 밖이면 요청하지 않는다.
    if not isinstance(photo_name, str) or not _GOOGLE_PHOTO_NAME_RE.match(photo_name):
        return None
    resp = await http.get(
        _GOOGLE_PHOTO_URL.format(name=photo_name),
        params={"maxWidthPx": _GOOGLE_PHOTO_MAX_WIDTH, "skipHttpRedirect": "true"},
    )
    resp.raise_for_status()
    uri = resp.json().get("photoUri")
    if not isinstance(uri, str) or not uri.startswith("https://"):
        return None
    host = (urlparse(uri).netloc or "").lower()
    return uri if host.endswith(".googleusercontent.com") else None


def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius_m = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius_m * math.asin(math.sqrt(a))


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
