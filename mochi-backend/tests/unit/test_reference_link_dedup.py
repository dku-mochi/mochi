"""관련 링크 dedup 단위 테스트.

기록 상세의 "지금 할 수 있어요"(원본/intent 링크)와 "관련 링크"(ResourceFinder)가
같은 자료를 가리키면 두 섹션에 동일 링크가 중복으로 뜬다. repository 매퍼가 응답 조립
시점에 ``source.url`` · intent ``payload.url`` 과 같은 URL 을 관련 링크에서 제외한다 —
회수>확장 우선순위라 원본 링크는 ② 섹션에 남기고 관련 링크엔 다른 자료만 남긴다.
(유튜브 쇼츠 캡처에서 recoverYoutubeUrl 복원 URL 이 양쪽에 중복되던 문제, 2026-06-15.)

DB 통합 fixture 가 없어 ORM row 를 인메모리로 구성한다 (기존 단위테스트 컨벤션).
"""

import json
from datetime import UTC, datetime
from uuid import uuid4

from app.modules.mochi_items.domain.entities import IngestChannel
from app.modules.mochi_items.infrastructure.orm import (
    EntityRow,
    IntentInstanceRow,
    MochiItemRow,
)
from app.modules.mochi_items.infrastructure.repository import (
    _canonical_link_key,
    _row_to_entity,
)


def _row(
    *,
    url: str | None = None,
    references: tuple[str, ...] = (),
    intent_urls: tuple[str, ...] = (),
) -> MochiItemRow:
    row = MochiItemRow(
        owner_id=uuid4(),
        channel=IngestChannel.SCREENSHOT.value,
        url=url,
        text=None,
        user_memo=None,
        captured_at=datetime.now(UTC),
    )
    row.id = uuid4()
    for ref_url in references:
        value = json.dumps({"url": ref_url, "title": "", "provider": "youtube"})
        row.entities.append(
            EntityRow(mochi_item_id=row.id, kind="reference_url", value=value, mochi_item=row)
        )
    for payload_url in intent_urls:
        row.intent_instances.append(
            IntentInstanceRow(
                owner_id=row.owner_id,
                intent_type="memo",
                payload={"url": payload_url},
                mochi_item=row,
            )
        )
    return row


# --- 정규화 키 ---


def test_canonical_link_key_equates_youtube_video_forms() -> None:
    """youtu.be / watch?v= / shorts/ / embed/ + m. 프리픽스는 같은 영상으로 환원된다."""
    keys = {
        _canonical_link_key("https://youtu.be/aRnD-jOINlM"),
        _canonical_link_key("https://www.youtube.com/watch?v=aRnD-jOINlM"),
        _canonical_link_key("https://m.youtube.com/watch?v=aRnD-jOINlM"),
        _canonical_link_key("https://youtube.com/shorts/aRnD-jOINlM"),
        _canonical_link_key("https://www.youtube.com/embed/aRnD-jOINlM"),
    }
    assert keys == {"youtube:aRnD-jOINlM"}


def test_canonical_link_key_distinguishes_different_videos() -> None:
    assert _canonical_link_key("https://youtu.be/aaa") != _canonical_link_key("https://youtu.be/bbb")


def test_canonical_link_key_strips_youtube_share_and_playlist_params() -> None:
    # 공유 링크(youtu.be ?si=)와 watch ?v=…&list=&t= 가 같은 영상으로 묶여야 실제 중복이 잡힌다.
    assert _canonical_link_key("https://youtu.be/abc?si=xY") == "youtube:abc"
    assert _canonical_link_key("https://www.youtube.com/watch?v=abc&list=PL1&t=10s") == "youtube:abc"


def test_canonical_link_key_preserves_query_case_for_non_youtube() -> None:
    # 쿼리 토큰/ID 는 대소문자 구분 (host·path 만 소문자화).
    assert _canonical_link_key("https://Shop.example.com/Goods?id=AbC") == "shop.example.com/goods?id=AbC"


# --- dedup ---


def test_reference_dropped_when_same_video_as_intent_payload() -> None:
    """쇼츠↔watch 표기가 달라도 같은 영상이면 관련 링크에서 제외된다(재현된 핵심 케이스)."""
    row = _row(
        intent_urls=("https://www.youtube.com/watch?v=aRnD-jOINlM",),
        references=("https://youtu.be/aRnD-jOINlM",),
    )
    assert _row_to_entity(row).reference_links == ()


def test_reference_dropped_when_same_as_source_url() -> None:
    row = _row(
        url="https://www.youtube.com/watch?v=aRnD-jOINlM",
        references=("https://youtube.com/shorts/aRnD-jOINlM",),
    )
    assert _row_to_entity(row).reference_links == ()


def test_unrelated_reference_is_kept() -> None:
    row = _row(
        intent_urls=("https://www.youtube.com/watch?v=aRnD-jOINlM",),
        references=("https://www.youtube.com/watch?v=DIFFERENT01",),
    )
    links = _row_to_entity(row).reference_links
    assert len(links) == 1
    assert links[0].url == "https://www.youtube.com/watch?v=DIFFERENT01"


def test_reference_kept_when_no_source_or_intent_url() -> None:
    """원본·intent URL 이 없으면(순수 관련 링크 item) 보존 — 회귀 방지."""
    row = _row(references=("https://www.youtube.com/watch?v=aRnD-jOINlM",))
    assert len(_row_to_entity(row).reference_links) == 1
