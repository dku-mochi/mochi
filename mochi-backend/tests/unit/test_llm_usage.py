"""LLM 토큰 사용량 추출 + 비용 추정 단위 테스트."""

from decimal import Decimal
from types import SimpleNamespace

from app.shared.llm_cost import estimate_cost_usd, has_pricing
from app.shared.llm_usage import extract_token_usage


def test_extract_usage_from_metadata() -> None:
    resp = SimpleNamespace(
        usage_metadata=SimpleNamespace(prompt_token_count=120, candidates_token_count=45)
    )
    assert extract_token_usage(resp) == (120, 45)


def test_extract_usage_missing_metadata() -> None:
    assert extract_token_usage(SimpleNamespace()) == (0, 0)
    assert extract_token_usage(SimpleNamespace(usage_metadata=None)) == (0, 0)


def test_extract_usage_none_counts() -> None:
    resp = SimpleNamespace(
        usage_metadata=SimpleNamespace(prompt_token_count=None, candidates_token_count=None)
    )
    assert extract_token_usage(resp) == (0, 0)


def test_extract_usage_includes_thinking_tokens() -> None:
    # thinking 토큰은 output 으로 과금 — candidates + thoughts 합산해야(채팅 thinking_budget=512).
    resp = SimpleNamespace(
        usage_metadata=SimpleNamespace(
            prompt_token_count=100, candidates_token_count=50, thoughts_token_count=30
        )
    )
    assert extract_token_usage(resp) == (100, 80)


def test_estimate_cost_known_model() -> None:
    # flash-lite: input 0.25 / output 1.50 USD per 1M → 1M in + 1M out = 1.75
    assert estimate_cost_usd("gemini-3.1-flash-lite", 1_000_000, 1_000_000) == Decimal("1.75")


def test_estimate_cost_unknown_model_is_none() -> None:
    assert estimate_cost_usd("totally-unknown-model", 100, 100) is None
    assert has_pricing("gemini-3.1-flash-lite") is True
    assert has_pricing("totally-unknown-model") is False
