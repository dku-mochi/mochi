"""LLM 비용 추정 — (모델, tokens_in, tokens_out) → USD.

단가는 행마다 저장된 모델명으로 *조회 시점에* 환산한다(과거 행도 현재 코드 단가표로
재계산). 단가는 거의 안 바뀌고, 바뀌면 표만 갱신하면 되므로 env 가 아니라 코드 상수로 둔다.

⚠️ 아래 단가는 code-review(codex) 웹조사 기준값이다. 청구의 단일 진실은 Vertex AI 공식 가격
(https://cloud.google.com/vertex-ai/generative-ai/pricing)이며, 청구서와 대조해 확정할 것.
"""

from decimal import Decimal

#: model → (input USD per 1M tokens, output USD per 1M tokens).
#: 멀티모달(이미지) 입력 토큰도 prompt_token_count 에 포함되므로 input 단가 하나로 처리.
#: output 단가는 thinking 토큰에도 동일 적용(usage 추출 시 candidates+thoughts 합산).
_PRICING_USD_PER_1M: dict[str, tuple[Decimal, Decimal]] = {
    # Vertex AI Standard(global) 기준 — codex 웹조사값, 공식 가격으로 재확인 필요.
    "gemini-3.1-flash-lite": (Decimal("0.25"), Decimal("1.50")),
    "gemini-3.5-flash": (Decimal("0.30"), Decimal("2.50")),
}


def estimate_cost_usd(model: str, tokens_in: int, tokens_out: int) -> Decimal | None:
    """USD 비용. 단가표에 없는 모델은 ``None``(비용 미상 — 0 으로 오도하지 않음)."""
    price = _PRICING_USD_PER_1M.get(model)
    if price is None:
        return None
    price_in, price_out = price
    return (Decimal(tokens_in) * price_in + Decimal(tokens_out) * price_out) / Decimal(1_000_000)


def has_pricing(model: str) -> bool:
    return model in _PRICING_USD_PER_1M
