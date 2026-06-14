"""사용자 우려 검증: 진짜 액세서리 캡처가 살아남는가 + 불일치 액션은 강등되는가.

룰('스킨/스티커' blocklist)을 제거하고 judge.picked 기반으로 바꾼 뒤, 진짜 그 부속품을
찾는 캡처(그립톡/폰케이스/키스킨/스티커)는 구매 액션으로 살아야 하고, query 와 다른
상품(로지텍 본품 vs 그립스킨)·다른 가게(노티드 vs 스케줄청담)는 judge 가 안 골라 강등돼야.

Run (cwd=mochi-backend):
  cd mochi-backend && uv run python ../lab/active/shopping-product-link/probe_accessory.py
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

CASES = [
    ("그립톡 (진짜 액세서리 캡처)", ["아이폰 투명 자석 그립톡"], "shop", "coupang", "coupang"),
    ("폰케이스 (진짜 액세서리)", ["아이폰 15 프로 맥세이프 투명 케이스"], "shop", "coupang", "coupang"),
    ("맥북 키스킨 (진짜 액세서리)", ["맥북 에어 m3 키스킨"], "shop", "coupang", "coupang"),
    ("다꾸 스티커 (진짜 액세서리)", ["디즈니 다이어리 꾸미기 스티커"], "shop", "general", "unknown"),
    ("로지텍 MX 마스터 3S (본품 — 부속품 끼면 강등)", ["로지텍 MX 마스터 3S"], "shop", "electronics", "unknown"),
    ("노티드 청담 (다른 가게 강등)", ["노티드 청담"], "local", "local", "naver_map"),
]


async def main() -> None:
    tool = ResourceFinderTool()
    for label, queries, category, profile, source in CASES:
        payload = ResourceFinderInput(
            queries=queries, category=category, rank_profile=profile, source_app=source
        )
        print("\n" + "=" * 76)
        print(f"### {label}")
        print(f"  query={queries}")
        try:
            out, _ = await tool.run(payload)
        except Exception as exc:  # noqa: BLE001
            print(f"  ⚠️ {type(exc).__name__}: {exc}")
            continue
        print(f"  judge: useful={out.useful} u={out.usefulness} | {out.comment[:90]}")
        for i, r in enumerate(out.ranked_urls, 1):
            print(f"  {i}. [{r.provider}/{r.role}] {r.label} — {r.url[:72]}")


if __name__ == "__main__":
    asyncio.run(main())
