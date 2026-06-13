"""LLM 토큰/비용 사용량 리포트 — 일별·사용자별·아이템별 집계.

llm_usage 테이블을 집계해 평균 토큰과 추정 비용(USD)을 출력한다. 비용은 행마다 저장된
model 로 ``app.shared.llm_cost`` 단가표를 적용한다(단가 미등록 모델은 비용 미상).

usage:
  uv run python scripts/llm_usage_report.py --by day
  uv run python scripts/llm_usage_report.py --by user
  uv run python scripts/llm_usage_report.py --by item   # capture 만(아이템 귀속)

ad-hoc 으로 직접 쿼리해도 된다, 예:
  SELECT date(created_at), source, avg(tokens_in+tokens_out)
  FROM llm_usage GROUP BY 1, 2 ORDER BY 1 DESC;
"""

import argparse
import asyncio
from decimal import Decimal

from sqlalchemy import text

from app.core.db import get_session_factory
from app.shared.llm_cost import estimate_cost_usd

# 각 그룹키 + (source, model) 별로 호출수·토큰합·평균을 뽑는다. 비용은 model 단가로 행 그룹마다 환산.
_QUERIES: dict[str, str] = {
    "day": """
        SELECT date(created_at) AS bucket, source, model,
               count(*) AS calls,
               sum(tokens_in) AS tin, sum(tokens_out) AS tout,
               avg(tokens_in + tokens_out) AS avg_total
        FROM llm_usage
        GROUP BY date(created_at), source, model
        ORDER BY bucket DESC, source
    """,
    "user": """
        SELECT owner_id::text AS bucket, source, model,
               count(*) AS calls,
               sum(tokens_in) AS tin, sum(tokens_out) AS tout,
               avg(tokens_in + tokens_out) AS avg_total
        FROM llm_usage
        GROUP BY owner_id, source, model
        ORDER BY sum(tokens_in + tokens_out) DESC
    """,
    "item": """
        SELECT mochi_item_id::text AS bucket, source, model,
               count(*) AS calls,
               sum(tokens_in) AS tin, sum(tokens_out) AS tout,
               avg(tokens_in + tokens_out) AS avg_total
        FROM llm_usage
        WHERE source = 'capture' AND mochi_item_id IS NOT NULL
        GROUP BY mochi_item_id, source, model
        ORDER BY sum(tokens_in + tokens_out) DESC
    """,
}


async def _run(by: str) -> None:
    sql = text(_QUERIES[by])
    async with get_session_factory()() as session:
        rows = (await session.execute(sql)).all()

    print(f"# LLM usage by {by}")
    print(f"{'bucket':<40} {'source':<8} {'model':<24} {'calls':>6} {'tok_in':>10} {'tok_out':>10} {'avg':>8} {'cost$':>10}")
    total_cost = Decimal(0)
    cost_known = True
    for r in rows:
        cost = estimate_cost_usd(r.model, int(r.tin or 0), int(r.tout or 0))
        if cost is None:
            cost_known = False
            cost_str = "?"
        else:
            total_cost += cost
            cost_str = f"{cost:.4f}"
        print(
            f"{r.bucket:<40} {r.source:<8} {r.model:<24} {int(r.calls):>6} "
            f"{int(r.tin or 0):>10} {int(r.tout or 0):>10} {float(r.avg_total or 0):>8.0f} {cost_str:>10}"
        )
    suffix = "" if cost_known else "  (일부 모델 단가 미등록 — app/shared/llm_cost.py 갱신 필요)"
    print(f"\nTOTAL estimated cost: ${total_cost:.4f}{suffix}")


def main() -> None:
    parser = argparse.ArgumentParser(description="LLM 토큰/비용 사용량 리포트")
    parser.add_argument("--by", choices=sorted(_QUERIES), default="day")
    args = parser.parse_args()
    asyncio.run(_run(args.by))


if __name__ == "__main__":
    main()
