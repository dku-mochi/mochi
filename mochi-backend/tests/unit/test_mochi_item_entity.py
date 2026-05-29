"""MochiItem aggregate root 의 multi-intent invariant 와 swap_primary 검증.

분류 결과는 worker(`apply_analysis`)가 채운다 — 도메인은 채워진 상태를 직접 표현한다
(구 ``from_classification`` 생성자는 동기 분류 경로와 함께 제거됨).
"""

import pytest

from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    MochiItem,
)
from app.shared.intent import Intent


def _source(channel: IngestChannel = IngestChannel.SCREENSHOT) -> IngestSource:
    return IngestSource(channel=channel)


def _classified_item() -> MochiItem:
    """LLM 분류가 채워진 상태의 MochiItem (worker apply_analysis 결과와 동치)."""
    source = _source()
    return MochiItem(
        id=source.id,
        source=source,
        intent=Intent.TODO,
        secondary_intents=(Intent.KNOWLEDGE, Intent.MEMO),
        intent_applicability={Intent.TODO: 0.95, Intent.KNOWLEDGE: 0.75, Intent.MEMO: 0.40},
    )


def test_default_intent_is_memo_for_unclassified_ingestion() -> None:
    """일반 ingestion (분류 전) 의 fallback default 는 MEMO 다."""
    item = MochiItem(id=_source().id, source=_source())
    assert item.intent is Intent.MEMO
    assert item.secondary_intents == ()
    assert item.intent_applicability == {}
    assert item.intent_candidates == ()


def test_post_init_rejects_primary_in_secondary() -> None:
    with pytest.raises(ValueError, match="must not appear in secondary"):
        MochiItem(
            id=_source().id,
            source=_source(),
            intent=Intent.TODO,
            secondary_intents=(Intent.TODO, Intent.MEMO),
        )


def test_post_init_rejects_duplicate_secondary() -> None:
    with pytest.raises(ValueError, match="must not contain duplicates"):
        MochiItem(
            id=_source().id,
            source=_source(),
            intent=Intent.TODO,
            secondary_intents=(Intent.MEMO, Intent.MEMO),
        )


def test_post_init_rejects_out_of_range_applicability() -> None:
    with pytest.raises(ValueError, match="must be in"):
        MochiItem(
            id=_source().id,
            source=_source(),
            intent=Intent.TODO,
            intent_applicability={Intent.TODO: 1.2},
        )


def test_swap_primary_moves_old_primary_to_front_of_secondary() -> None:
    item = _classified_item()
    item.swap_primary(Intent.KNOWLEDGE)

    assert item.intent is Intent.KNOWLEDGE
    # 이전 primary (TODO) 가 secondary 의 맨 앞으로 이동, KNOWLEDGE 는 secondary 에서 제거.
    assert item.secondary_intents == (Intent.TODO, Intent.MEMO)
    # applicability 는 보존 — calibration 자료로 유지.
    assert item.intent_applicability[Intent.TODO] == 0.95


def test_swap_primary_to_same_intent_is_noop() -> None:
    item = _classified_item()
    secondary_before = item.secondary_intents
    item.swap_primary(Intent.TODO)

    assert item.intent is Intent.TODO
    assert item.secondary_intents == secondary_before


def test_swap_primary_to_intent_not_in_secondary_still_demotes_old() -> None:
    """알림 외 자유 입력으로 LLM 이 안 본 intent 를 골랐을 때도 swap 이 동작한다."""
    item = _classified_item()
    item.swap_primary(Intent.SCHEDULE)

    assert item.intent is Intent.SCHEDULE
    assert item.secondary_intents == (Intent.TODO, Intent.KNOWLEDGE, Intent.MEMO)
