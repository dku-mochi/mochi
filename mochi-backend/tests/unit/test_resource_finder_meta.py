"""resource_finder 표시 메타 단위테스트.

검색 시점에 받은 메타(가격/업종·지역/요약문/브랜드)를 카드 표시용 subtitle·price_text 로
환원(``_display_meta``)하고, 값이 있을 때만 entity JSON 에 싣는지(``_reference_entity_value``,
메타 없는 링크 폴백) 검증한다. 더불어 judge 가 picks 판단 시 같은 메타를 보는지(``_render``)도
회귀로 박는다 — 사용자에게 보이는 근거와 judge 가 본 근거가 같아야 신뢰가 일관된다.
"""

import json

from app.modules.agent.infrastructure.tools.resource_finder import (
    RankedUrl,
    ResourceFinderInput,
    _display_meta,
    _reference_entity_value,
    _render,
)


def _ranked(**over: object) -> RankedUrl:
    base: dict[str, object] = {
        "url": "https://x.com", "title": "t", "tier_num": 4.0,
        "tier_label": "tier4_info", "label": "보기", "provider": "info",
        "role": "read", "source": "naver:blog", "rank_profile": "general",
    }
    base.update(over)
    return RankedUrl(**base)  # type: ignore[arg-type]


def test_display_meta_shop_price_and_brand() -> None:
    subtitle, price = _display_meta(
        {"lprice": "18900", "brand": "토리든", "mallName": "올리브영"}
    )
    assert price == "18,900원"
    assert subtitle == "토리든"   # mallName 은 provider 와 겹쳐 안 쓴다


def test_display_meta_local_category_and_region() -> None:
    subtitle, price = _display_meta(
        {"category": "양식", "roadAddress": "서울특별시 강남구 도산대로 123"}
    )
    assert subtitle == "양식 · 서울특별시 강남구"   # 주소는 앞 2토큰(시·구)만
    assert price == ""


def test_display_meta_blog_uses_truncated_description() -> None:
    subtitle, price = _display_meta({"description": "토리든 세럼 발림성 솔직 후기 " * 10})
    assert subtitle.startswith("토리든 세럼")
    assert len(subtitle) <= 80
    assert price == ""


def test_display_meta_empty_when_no_meta() -> None:
    assert _display_meta({"title": "화면 속 링크"}) == ("", "")


def test_reference_entity_value_omits_empty_meta_keys() -> None:
    payload = json.loads(_reference_entity_value(_ranked(), None))
    assert "subtitle" not in payload
    assert "priceText" not in payload
    assert "usefulness" not in payload


def test_reference_entity_value_includes_meta_when_present() -> None:
    row = _ranked(provider="oliveyoung", role="buy", source="naver:shop",
                  rank_profile="cosmetics", subtitle="토리든", price_text="18,900원")
    payload = json.loads(_reference_entity_value(row, 5))
    assert payload["subtitle"] == "토리든"
    assert payload["priceText"] == "18,900원"
    assert payload["usefulness"] == 5


def test_render_exposes_metadata_to_judge() -> None:
    """judge 가 picks 를 고를 때 가격·요약문을 보도록 _render 가 노출하는지(회귀 방지)."""
    payload = ResourceFinderInput(queries=["토리든 세럼"], category="shop")
    collected = [{
        "title": "토리든 세럼", "link": "https://x.com",
        "lprice": "18900", "mallName": "올리브영", "brand": "토리든",
        "description": "저분자 히알루론산 세럼",
    }]
    rendered = _render(payload, collected)
    assert "18900" in rendered
    assert "토리든" in rendered
    assert "저분자 히알루론산" in rendered
