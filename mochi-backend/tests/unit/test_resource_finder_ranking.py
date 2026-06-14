import json

from app.modules.agent.infrastructure.tools.resource_finder import (
    RankedUrl,
    ResourceFinderInput,
    _dedupe_key,
    _exact_picks,
    _fallback_search_items,
    _FinalJudge,
    _Pick,
    _rank_results,
    _reference_entity_value,
)


def test_local_ranks_map_first_then_catchtable() -> None:
    """장소 캡처: 네이버지도(액션) 1위 → 캐치테이블(액션) 2위. 액션 믹스."""
    payload = ResourceFinderInput(
        queries=["몽탄 예약"],
        category="local",
        rank_profile="local",
        source_app="naver_map",
    )
    # naver local 이 매칭됐다고 보고 지도 fallback 생성(place_confirmed=True).
    catchtable = "https://app.catchtable.co.kr/ct/shop/mongtan"
    collected = _fallback_search_items(payload, place_confirmed=True) + [
        {"title": "몽탄 - 캐치테이블", "link": catchtable, "source": "naver:webkr"}
    ]
    # 합성 지도는 검색-상태 링크라 picks 없이도 액션. catchtable(실 예약)만 대상으로 pick.
    judge = _FinalJudge(
        useful=True,
        picks=[_Pick(url=catchtable, usefulness=5)],
        comment="장소와 예약 링크가 맞다.",
    )

    ranked = _rank_results(judge, collected, payload)

    assert ranked[0].provider == "naver_map"
    assert ranked[0].label == "네이버 지도에서 보기"
    assert ranked[1].provider == "catchtable"


def test_local_no_map_when_naver_local_misses() -> None:
    """네이버 local 0건이면 지도 검색 fallback 을 만들지 않는다(해외 호텔 깨진 링크 차단)."""
    payload = ResourceFinderInput(
        queries=["리치몬드호텔 야마가타 에키마에 예약"],
        category="local",
        rank_profile="local",
    )
    assert _fallback_search_items(payload, place_confirmed=False) == []


def test_top3_mixes_action_and_reference() -> None:
    """액션이 하나여도 참고 자료가 top3 에 섞인다 — 지도/예약 overfit 방지."""
    payload = ResourceFinderInput(
        queries=["양은이네 신대방삼거리역직영점"],
        category="local",
        rank_profile="local",
        source_app="naver_map",
    )
    collected = _fallback_search_items(payload, place_confirmed=True) + [
        {"title": "방문 후기", "link": "https://blog.naver.com/x/1", "source": "naver:webkr"},
        {"title": "릴스", "link": "https://www.instagram.com/reel/AAA", "source": "tavily"},
    ]
    # picks=[] 이지만 합성 지도(검색-상태)는 fallback 액션으로 살아남는다.
    judge = _FinalJudge(useful=True, picks=[], comment="ok")

    ranked = _rank_results(judge, collected, payload)
    providers = [r.provider for r in ranked]

    assert ranked[0].provider == "naver_map"           # 합성 지도 액션 1위
    assert any(p in {"info", "social"} for p in providers)  # 참고 자료 동반


def test_coupang_source_adds_search_fallback() -> None:
    payload = ResourceFinderInput(
        queries=["탐사수 2L 12개"],
        category="shop",
        rank_profile="coupang",
        source_app="coupang",
    )

    fallback = _fallback_search_items(payload, place_confirmed=False)

    assert fallback[0]["source"] == "synthetic:coupang_search"
    assert fallback[0]["link"].startswith("https://www.coupang.com/np/search?")


def test_unpicked_action_demoted_below_picked() -> None:
    """judge 가 안 고른 액션(엉뚱한 가게/다른 SKU)은 참고로 강등돼 picked 액션 뒤로.

    로지텍 마우스 query 에 '그립 스킨 스티커'가 끼면 judge 가 본품만 picked → 부속품은 강등.
    룰('스킨/스티커' 단어)로 막지 않으므로, 진짜 그 부속품을 찾는 캡처는 죽지 않는다.
    """
    payload = ResourceFinderInput(
        queries=["로지텍 MX 마스터 3S"], category="shop", rank_profile="electronics"
    )
    accessory = "https://smartstore.naver.com/main/products/1"
    official = "https://www.logitech.com/p/mx-master-3s"
    collected = [
        {"title": "로지텍 마우스 그립 스킨 스티커", "link": accessory, "source": "tavily"},
        {"title": "로지텍 MX 마스터 3S 공식", "link": official, "source": "tavily"},
    ]
    judge = _FinalJudge(
        useful=True, picks=[_Pick(url=official, usefulness=5)], comment="본품만"
    )

    ranked = _rank_results(judge, collected, payload)

    assert ranked[0].url == official                       # judge 가 인정한 본품이 1위
    acc = [r for r in ranked if r.url == accessory]
    if acc:                                                # 강등은 role/label/CTA 까지 반영
        assert acc[0].role == "reference"
        assert acc[0].label == "관련 링크 보기"


def test_picked_match_is_normalized() -> None:
    """judge 가 trailing slash 등 URL 을 살짝 바꿔 picked 해도 정규화로 매칭된다."""
    payload = ResourceFinderInput(
        queries=["몽탄"], category="local", rank_profile="local", source_app="naver_map"
    )
    target = "https://app.catchtable.co.kr/ct/shop/mongtan"
    other = "https://app.catchtable.co.kr/ct/shop/other_shop"
    collected = [
        {"title": "몽탄 - 캐치테이블", "link": target, "source": "naver:webkr"},
        {"title": "다른 가게", "link": other, "source": "naver:webkr"},
    ]
    judge = _FinalJudge(
        useful=True, picks=[_Pick(url=target + "/", usefulness=5)], comment="ok"
    )

    ranked = _rank_results(judge, collected, payload)
    by_url = {r.url: r for r in ranked}

    assert by_url[target].role == "reserve"                # 정규화 매칭 → picked 로 인정
    if other in by_url:                                    # picked 아님 → 강등
        assert by_url[other].role == "reference"


def test_accessory_kept_when_user_wants_it() -> None:
    """사용자가 그 부속품(그립톡)을 찾는 캡처면 구매 액션으로 살아남는다 — overfit 방지."""
    payload = ResourceFinderInput(
        queries=["아이폰 그립톡"], category="shop", rank_profile="coupang", source_app="coupang"
    )
    griptok = "https://www.coupang.com/vp/products/999"
    collected = [
        {"title": "투명 자석 그립톡", "link": griptok, "source": "tavily"},
        {"title": "그립톡 추천 블로그", "link": "https://blog.naver.com/x/3", "source": "naver:webkr"},
    ]
    judge = _FinalJudge(
        useful=True, picks=[_Pick(url=griptok, usefulness=5)], comment="그립톡 상품"
    )

    ranked = _rank_results(judge, collected, payload)
    top = ranked[0]

    assert top.url == griptok                # 부속품이지만 대상이므로 구매 액션 1위
    assert top.provider == "coupang"
    assert top.role == "buy"


def test_picks_empty_demotes_real_action_keeps_synthetic() -> None:
    """picks=[] (judge 확신 0): 실 PDP 는 reference 로 강등, 합성 검색 링크만 액션 유지.

    경계는 'synthetic 여부'가 아니라 '검색-상태 링크 종류'다(codex 토론). 실 PDP 는 '이게
    그 대상'이라는 주장이라 확신이 없으면 강등하지만, 합성 검색은 핸드오프라 살린다.
    """
    payload = ResourceFinderInput(
        queries=["탐사수 2L 12개"], category="shop", rank_profile="coupang", source_app="coupang"
    )
    real_pdp = "https://www.coupang.com/vp/products/123"
    collected = _fallback_search_items(payload, place_confirmed=False) + [
        {"title": "탐사수 2L", "link": real_pdp, "source": "tavily"},
    ]
    judge = _FinalJudge(useful=True, picks=[], comment="딱 그건 못 찾았지만 참고용")

    ranked = _rank_results(judge, collected, payload)
    by_url = {r.url: r for r in ranked}

    synthetic = next(r for r in ranked if r.source == "synthetic:coupang_search")
    assert synthetic.role == "buy"                 # 합성 검색 링크는 fallback 액션
    assert by_url[real_pdp].role == "reference"    # 실 PDP 는 확신 0 이라 강등


def test_reference_entity_usefulness_per_url() -> None:
    """pick 된 URL 만 usefulness 를 싣고, pick 밖은 키 자체를 뺀다(iOS 다중 점등 해소)."""
    row = RankedUrl(
        url="https://www.coupang.com/vp/products/1", title="t", tier_num=3.0,
        tier_label="tier3_openmarket", label="쿠팡에서 보기", provider="coupang",
        role="buy", source="tavily", rank_profile="coupang",
    )
    picked = json.loads(_reference_entity_value(row, 5))
    unpicked = json.loads(_reference_entity_value(row, None))

    assert picked["usefulness"] == 5
    assert "usefulness" not in unpicked          # None → 키 생략 → iOS 뱃지 OFF


def test_exact_picks_drops_below_four() -> None:
    """judge 가 빗나간(3 이하) 링크를 picks 에 넣어도 _exact_picks 가 걸러낸다 — 스키마
    hard-fail 없이(structured-output 범위 위반 내성), 그 URL 은 reference 로 자연 강등."""
    picks = [
        _Pick(url="https://a.com", usefulness=5),
        _Pick(url="https://b.com", usefulness=3),
        _Pick(url="https://c.com", usefulness=4),
    ]
    kept = [p.url for p in _exact_picks(picks)]
    assert kept == ["https://a.com", "https://c.com"]


def test_dedupe_key_distinguishes_query_identified_pages() -> None:
    """쿼리로 식별되는 페이지는 host+path 가 같아도 다른 키 — 한 pick 이 다른 URL 에
    usefulness 를 잘못 전염시키지 않게(codex P1)."""
    a = "https://www.youtube.com/watch?v=AAA"
    b = "https://www.youtube.com/watch?v=BBB"
    assert _dedupe_key(a) != _dedupe_key(b)
    # 단 trailing slash·m. 등 비식별 변형은 여전히 같은 키로 정규화(picked 매칭 안 깨짐).
    assert _dedupe_key("https://m.catchtable.co.kr/ct/shop/x/") == _dedupe_key(
        "https://catchtable.co.kr/ct/shop/x"
    )


def test_noise_domains_dropped() -> None:
    """pinterest·기계번역 미러 같은 noise 도메인은 후보에서 제거."""
    payload = ResourceFinderInput(queries=["탐사수 2L"], category="shop", rank_profile="coupang")
    collected = [
        {"title": "탐사수", "link": "https://www.coupang.com/vp/products/1", "source": "tavily"},
        {"title": "pin", "link": "https://kr.pinterest.com/pin/123", "source": "tavily"},
        {"title": "yamagata", "link": "http://ko-22002.site-translation.com/x", "source": "tavily"},
    ]
    judge = _FinalJudge(useful=True, picks=[], comment="ok")

    urls = [r.url for r in _rank_results(judge, collected, payload)]

    assert not any("pinterest" in u or "site-translation" in u for u in urls)


def test_useless_judge_returns_empty() -> None:
    payload = ResourceFinderInput(queries=["뭔가"], category="web", rank_profile="web")
    collected = [{"title": "x", "link": "https://example.com", "source": "tavily"}]
    judge = _FinalJudge(useful=False, picks=[], comment="무관")

    assert _rank_results(judge, collected, payload) == []
