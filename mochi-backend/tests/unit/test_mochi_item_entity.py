"""MochiItem aggregate root 의 multi-intent invariant 와 변환 메서드 검증."""

import pytest

from app.modules.mochi_items.domain.entities import (
    IngestChannel,
    IngestSource,
    MochiItem,
)
from app.modules.mochi_items.domain.value_objects import (
    IntentClassification,
    IntentClassificationResult,
)
from app.shared.intent import Intent


def _source(channel: IngestChannel = IngestChannel.SCREENSHOT) -> IngestSource:
    return IngestSource(channel=channel)


def _result(
    *triples: tuple[str, Intent, float],
) -> IntentClassificationResult:
    candidates = tuple(
        IntentClassification(label=label, intent=intent, applicability=score, reasoning="-")
        for label, intent, score in triples
    )
    return IntentClassificationResult(candidates=candidates)


def test_default_intent_is_memo_for_unclassified_ingestion() -> None:
    """일반 ingestion (분류 전) 의 fallback default 는 MEMO 다."""
    item = MochiItem(id=_source().id, source=_source())
    assert item.intent is Intent.MEMO
    assert item.secondary_intents == ()
    assert item.intent_applicability == {}


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


def test_from_classification_picks_top_applicability_as_primary() -> None:
    result = _result(
        ("구매 고민", Intent.TODO, 0.95),
        ("가격 비교", Intent.KNOWLEDGE, 0.75),
        ("위시리스트", Intent.MEMO, 0.40),
    )
    source = _source()
    item = MochiItem.from_classification(source=source, classification=result)

    assert item.intent is Intent.TODO
    assert item.secondary_intents == (Intent.KNOWLEDGE, Intent.MEMO)
    assert item.intent_applicability == {
        Intent.TODO: 0.95,
        Intent.KNOWLEDGE: 0.75,
        Intent.MEMO: 0.40,
    }


def test_from_classification_deduplicates_same_intent_across_candidates() -> None:
    """두 후보가 같은 intent 매핑이면 secondary 에 한 번만 등장하고 applicability 는 최댓값."""
    result = _result(
        ("회신", Intent.TODO, 0.9),
        ("연락처 저장", Intent.TODO, 0.55),
        ("대화 박제", Intent.MEMO, 0.6),
    )
    item = MochiItem.from_classification(source=_source(), classification=result)

    assert item.intent is Intent.TODO
    assert item.secondary_intents == (Intent.MEMO,)
    assert item.intent_applicability == {Intent.TODO: 0.9, Intent.MEMO: 0.6}


def test_swap_primary_moves_old_primary_to_front_of_secondary() -> None:
    result = _result(
        ("구매 고민", Intent.TODO, 0.95),
        ("가격 비교", Intent.KNOWLEDGE, 0.75),
        ("위시리스트", Intent.MEMO, 0.40),
    )
    item = MochiItem.from_classification(source=_source(), classification=result)
    item.swap_primary(Intent.KNOWLEDGE)

    assert item.intent is Intent.KNOWLEDGE
    # 이전 primary (TODO) 가 secondary 의 맨 앞으로 이동, KNOWLEDGE 는 secondary 에서 제거.
    assert item.secondary_intents == (Intent.TODO, Intent.MEMO)
    # applicability 는 보존 — calibration 자료로 유지.
    assert item.intent_applicability[Intent.TODO] == 0.95


def test_swap_primary_to_same_intent_is_noop() -> None:
    result = _result(
        ("구매 고민", Intent.TODO, 0.95),
        ("가격 비교", Intent.KNOWLEDGE, 0.75),
        ("위시리스트", Intent.MEMO, 0.40),
    )
    item = MochiItem.from_classification(source=_source(), classification=result)
    secondary_before = item.secondary_intents
    item.swap_primary(Intent.TODO)

    assert item.intent is Intent.TODO
    assert item.secondary_intents == secondary_before


def test_swap_primary_to_intent_not_in_secondary_still_demotes_old() -> None:
    """알림 외 자유 입력으로 LLM 이 안 본 intent 를 골랐을 때도 swap 이 동작한다."""
    result = _result(
        ("구매 고민", Intent.TODO, 0.95),
        ("가격 비교", Intent.KNOWLEDGE, 0.75),
        ("위시리스트", Intent.MEMO, 0.40),
    )
    item = MochiItem.from_classification(source=_source(), classification=result)
    item.swap_primary(Intent.SCHEDULE)

    assert item.intent is Intent.SCHEDULE
    assert item.secondary_intents == (Intent.TODO, Intent.KNOWLEDGE, Intent.MEMO)
