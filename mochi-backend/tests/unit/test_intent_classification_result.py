"""IntentClassificationResult 의 derive 로직 검증.

핵심 회귀 방지 케이스 — 2026-05-25 codex 리뷰가 잡은 0.0 후보 누락 버그.
"""

import pytest

from app.modules.mochi_items.domain.value_objects import (
    IntentClassification,
    IntentClassificationResult,
)
from app.shared.intent import Intent


def _r(*triples: tuple[Intent, float]) -> IntentClassificationResult:
    return IntentClassificationResult(
        candidates=tuple(
            IntentClassification(label="x", intent=i, applicability=a, reasoning="-")
            for i, a in triples
        )
    )


def test_requires_exactly_three_candidates() -> None:
    with pytest.raises(ValueError, match="exactly 3 candidates"):
        IntentClassificationResult(candidates=())


def test_classification_rejects_empty_label() -> None:
    with pytest.raises(ValueError, match="non-empty"):
        IntentClassification(label="   ", intent=Intent.TODO, applicability=0.5, reasoning="-")


def test_classification_rejects_out_of_range_applicability() -> None:
    with pytest.raises(ValueError, match=r"\[0, 1\]"):
        IntentClassification(label="x", intent=Intent.TODO, applicability=1.5, reasoning="-")


def test_primary_is_highest_applicability_candidate() -> None:
    r = _r(
        (Intent.MEMO, 0.4),
        (Intent.TODO, 0.95),
        (Intent.KNOWLEDGE, 0.7),
    )
    assert r.primary_intent is Intent.TODO


def test_primary_tie_breaks_to_first_seen() -> None:
    """동률 시 입력 순서가 빠른 후보가 primary."""
    r = _r(
        (Intent.MEMO, 0.8),
        (Intent.TODO, 0.8),
        (Intent.KNOWLEDGE, 0.4),
    )
    assert r.primary_intent is Intent.MEMO


def test_secondary_is_descending_applicability_excluding_primary() -> None:
    r = _r(
        (Intent.TODO, 0.95),
        (Intent.KNOWLEDGE, 0.75),
        (Intent.MEMO, 0.40),
    )
    assert r.secondary_intents == (Intent.KNOWLEDGE, Intent.MEMO)


def test_secondary_dedupes_same_intent_across_candidates() -> None:
    r = _r(
        (Intent.TODO, 0.9),
        (Intent.TODO, 0.55),
        (Intent.MEMO, 0.6),
    )
    # primary=TODO, secondary 에는 TODO 제외 후 MEMO 만.
    assert r.primary_intent is Intent.TODO
    assert r.secondary_intents == (Intent.MEMO,)


def test_applicability_map_takes_max_when_same_intent_repeats() -> None:
    r = _r(
        (Intent.TODO, 0.9),
        (Intent.TODO, 0.55),
        (Intent.MEMO, 0.6),
    )
    assert r.applicability_map == {Intent.TODO: 0.9, Intent.MEMO: 0.6}


def test_applicability_map_preserves_explicit_zero() -> None:
    """후보가 명시적으로 applicability=0.0 으로 등장하면 그 값이 누락되지 않고 0.0 으로 보존된다.

    2026-05-25 codex 리뷰가 잡은 회귀 — 이전 코드는 ``c.applicability > current`` 비교라
    첫 진입의 0.0 이 누락됐다.
    """
    r = _r(
        (Intent.TODO, 0.0),
        (Intent.MEMO, 0.7),
        (Intent.KNOWLEDGE, 0.3),
    )
    assert r.applicability_map == {Intent.TODO: 0.0, Intent.MEMO: 0.7, Intent.KNOWLEDGE: 0.3}


def test_applicability_map_omits_intents_not_in_candidates() -> None:
    """후보에 등장 안 한 intent 는 키에 포함되지 않는다 ("측정 안 됨" ≠ "0 점")."""
    r = _r(
        (Intent.TODO, 0.9),
        (Intent.MEMO, 0.6),
        (Intent.KNOWLEDGE, 0.4),
    )
    assert Intent.SCHEDULE not in r.applicability_map
