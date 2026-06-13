"""LLM 토큰 사용량 계측 — google-genai usage_metadata 추출 + llm_usage 행 적재.

캡처(agent loop)·채팅(chat run) 두 경로가 공유한다. 추출은 순수 함수, 적재는 호출자가
가진 ``AsyncSession`` 을 받아 raw SQL 로 INSERT(orchestrator 의 기존 raw SQL 영속과 동일 패턴).
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


def extract_token_usage(response_or_chunk: object) -> tuple[int, int]:
    """google-genai 응답/스트림 청크의 ``usage_metadata`` 에서 ``(tokens_in, tokens_out)``.

    - non-stream(``generate_content``): 응답에 바로 실린다.
    - stream(``generate_content_stream``): **마지막 청크에만** usage 가 실린다.
    - usage 가 없으면(fake·구버전·미수집) ``(0, 0)``.
    """
    meta = getattr(response_or_chunk, "usage_metadata", None)
    if meta is None:
        return (0, 0)
    tokens_in = getattr(meta, "prompt_token_count", None) or 0
    tokens_out = getattr(meta, "candidates_token_count", None) or 0
    # thinking 토큰(reasoning)도 output 으로 과금된다 — 채팅은 thinking_budget=512 라
    # 이걸 빼면 비용이 지속 과소집계된다(캡처는 budget=0 이라 0).
    thoughts = getattr(meta, "thoughts_token_count", None) or 0
    return (int(tokens_in), int(tokens_out) + int(thoughts))


_INSERT_SQL = text(
    """
    INSERT INTO llm_usage
        (source, owner_id, mochi_item_id, conversation_id, model, tokens_in, tokens_out, created_at)
    VALUES
        (:source, :owner_id, :mochi_item_id, :conversation_id, :model, :tokens_in, :tokens_out, :created_at)
    """
)


async def record_llm_usage(
    session: AsyncSession,
    *,
    source: str,
    owner_id: UUID,
    model: str,
    tokens_in: int,
    tokens_out: int,
    mochi_item_id: UUID | None = None,
    conversation_id: UUID | None = None,
) -> None:
    """llm_usage 행 1개를 INSERT + commit 한다.

    토큰이 0(usage 미수집)이어도 기록한다 — 호출 1회 = 행 1개라, 비용뿐 아니라 호출 빈도
    자체도 신호다. ``source`` 는 "capture" | "chat".
    """
    await session.execute(
        _INSERT_SQL,
        {
            "source": source,
            "owner_id": owner_id,
            "mochi_item_id": mochi_item_id,
            "conversation_id": conversation_id,
            "model": model,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "created_at": datetime.now(UTC),
        },
    )
    await session.commit()
