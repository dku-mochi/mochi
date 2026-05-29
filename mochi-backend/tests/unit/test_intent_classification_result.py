"""분석 derive 로직 + IntentClassification invariant 검증.

primary/secondary/applicability/confidence derive 는 worker 단일 경로 전환으로
``AgentOrchestrator._to_analysis_result`` 로 이동했다 (구 IntentClassificationResult).
confidence := 최상위 후보 applicability. 2026-05-25 codex 가 잡은 0.0 후보 누락 회귀 포함.
"""

import pytest
from pydantic import ValidationError

from app.modules.agent.application.orchestrator import _to_analysis_result
from app.modules.mochi_items.domain.value_objects import IntentClassification
from app.shared.intent import Intent


def _payload(*pairs: tuple[Intent, float]) -> dict:
    return {
        "summary": "s",
        "candidates": [
            {"label": "x", "intent": i.value, "applicability": a, "reasoning": "-"}
            for i, a in pairs
        ],
        "entities": [],
        "importance": 3,
        "model_version": "m",
    }


# --- IntentClassification invariant (value object) ---


def test_classification_rejects_empty_label() -> None:
    with pytest.raises(ValueError, match="non-empty"):
        IntentClassification(label="   ", intent=Intent.TODO, applicability=0.5, reasoning="-")


def test_classification_rejects_out_of_range_applicability() -> None:
    with pytest.raises(ValueError, match=r"\[0, 1\]"):
        IntentClassification(label="x", intent=Intent.TODO, applicability=1.5, reasoning="-")


# --- derive (orchestrator._to_analysis_result) ---


def test_primary_is_highest_applicability_candidate() -> None:
    r = _to_analysis_result(_payload((Intent.MEMO, 0.4), (Intent.TODO, 0.95), (Intent.KNOWLEDGE, 0.7)))
    assert r.intent is Intent.TODO
    assert r.confidence == 0.95


def test_primary_tie_breaks_to_first_seen() -> None:
    """동률 시 입력 순서가 빠른 후보가 primary."""
    r = _to_analysis_result(_payload((Intent.MEMO, 0.8), (Intent.TODO, 0.8), (Intent.KNOWLEDGE, 0.4)))
    assert r.intent is Intent.MEMO
    assert r.confidence == 0.8


def test_secondary_is_descending_applicability_excluding_primary() -> None:
    r = _to_analysis_result(_payload((Intent.TODO, 0.95), (Intent.KNOWLEDGE, 0.75), (Intent.MEMO, 0.40)))
    assert r.secondary_intents == (Intent.KNOWLEDGE, Intent.MEMO)


def test_secondary_dedupes_same_intent_across_candidates() -> None:
    r = _to_analysis_result(_payload((Intent.TODO, 0.9), (Intent.TODO, 0.55), (Intent.MEMO, 0.6)))
    assert r.intent is Intent.TODO
    assert r.secondary_intents == (Intent.MEMO,)


def test_applicability_map_takes_max_when_same_intent_repeats() -> None:
    r = _to_analysis_result(_payload((Intent.TODO, 0.9), (Intent.TODO, 0.55), (Intent.MEMO, 0.6)))
    assert r.intent_applicability == {Intent.TODO: 0.9, Intent.MEMO: 0.6}


def test_applicability_map_preserves_explicit_zero() -> None:
    """후보가 명시적으로 applicability=0.0 으로 등장하면 누락되지 않고 0.0 으로 보존된다.

    2026-05-25 codex 회귀 — 이전 코드는 ``c.applicability > current`` 비교라 첫 진입의 0.0 이 누락됐다.
    """
    r = _to_analysis_result(_payload((Intent.TODO, 0.0), (Intent.MEMO, 0.7), (Intent.KNOWLEDGE, 0.3)))
    assert r.intent_applicability == {Intent.TODO: 0.0, Intent.MEMO: 0.7, Intent.KNOWLEDGE: 0.3}
    assert r.confidence == 0.7  # primary = MEMO


def test_candidates_are_preserved_with_labels() -> None:
    r = _to_analysis_result(_payload((Intent.TODO, 0.9), (Intent.MEMO, 0.6), (Intent.KNOWLEDGE, 0.3)))
    assert len(r.candidates) == 3
    assert r.candidates[0].label == "x"


def test_empty_candidates_rejected() -> None:
    with pytest.raises(ValidationError):
        _to_analysis_result({"summary": "s", "candidates": [], "model_version": "m"})
