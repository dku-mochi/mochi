"""실제 ResourceFinderTool 을 라이브 경로 그대로(synthetic+search+judge+rank) 호출.

메인 에이전트가 '이렇게 불렀다면' 무엇이 나오는지 end-to-end 재현한다.

Run (cwd 가 mochi-backend 여야 .env 를 읽음):
  cd mochi-backend && uv run python ../lab/active/shopping-product-link/probe_tool_e2e.py
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "mochi-backend"))

from app.modules.agent.infrastructure.tools.resource_finder import (  # noqa: E402
    ResourceFinderInput,
    ResourceFinderTool,
)

CASES: list[tuple[str, ResourceFinderInput]] = [
    (
        "문제1-A: 호텔 local+예약 (메인이 실제로 부른 추정)",
        ResourceFinderInput(
            queries=["리치몬드호텔 야마가타 에키마에 예약"],
            category="local",
            rank_profile="local",
        ),
    ),
    (
        "문제1-B: 호텔 web/event_booking (대안 라우팅)",
        ResourceFinderInput(
            queries=["리치몬드호텔 야마가타 에키마에", "Richmond Hotel Yamagata"],
            category="web",
            rank_profile="event_booking",
        ),
    ),
    (
        "문제2: 양은이네 local+naver_map (캐치테이블 미입점 → 지도+참고 믹스 기대)",
        ResourceFinderInput(
            queries=["양은이네 신대방삼거리역직영점"],
            category="local",
            source_app="naver_map",
            rank_profile="local",
        ),
    ),
    (
        "맛집: 두툼 (지도+캐치테이블+참고 믹스 기대)",
        ResourceFinderInput(queries=["두툼 강남"], category="local",
                            source_app="naver_map", rank_profile="local"),
    ),
    (
        "맛집: 차경 해방촌",
        ResourceFinderInput(queries=["차경 해방촌"], category="local",
                            source_app="naver_map", rank_profile="local"),
    ),
    (
        "맛집: 파스타타타 을지로",
        ResourceFinderInput(queries=["파스타타타 을지로"], category="local",
                            source_app="naver_map", rank_profile="local"),
    ),
]


async def main() -> None:
    tool = ResourceFinderTool()
    for label, payload in CASES:
        print("\n" + "=" * 76)
        print(label)
        print(f"  in: queries={payload.queries} category={payload.category} "
              f"profile={payload.rank_profile} source_app={payload.source_app}")
        try:
            out, usage = await tool.run(payload)
        except Exception as exc:  # noqa: BLE001
            print(f"  ⚠️ {type(exc).__name__}: {exc}")
            continue
        print(f"  judge: useful={out.useful} usefulness={out.usefulness} "
              f"| {out.comment}")
        print(f"  cost: tin={usage.tokens_in} tout={usage.tokens_out} "
              f"latency={usage.latency_ms}ms")
        if not out.ranked_urls:
            print("  ranked: (빈손)")
        for i, r in enumerate(out.ranked_urls, 1):
            print(f"  {i}. [{r.provider}/{r.tier_label}] {r.label}")
            print(f"     {r.url}")
            print(f"     src={r.source}")


if __name__ == "__main__":
    asyncio.run(main())
