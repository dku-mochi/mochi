"""개선된 ResourceFinderTool 을 20건 키워드로 실제 실행 → 결과 JSON.

카테고리 다양하게(맛집/카페/화장품/패션/쿠팡/전자/전시/큐레이션/해외호텔) 깔아
"바로 액션 + 참고 자료 믹스 / 지도·예약 overfit 여부"를 LLM-judge 가 평가할 자료를 만든다.

Run (cwd=mochi-backend):
  cd mochi-backend && uv run python ../lab/active/shopping-product-link/eval_20cases.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "mochi-backend"))
OUT = REPO_ROOT / "lab/active/shopping-product-link/results/eval_20cases.json"

from app.modules.agent.infrastructure.tools.resource_finder import (  # noqa: E402
    ResourceFinderInput,
    ResourceFinderTool,
)

# (label, queries, category, rank_profile, source_app)
CASES: list[tuple] = [
    ("두툼 강남 (맛집)", ["두툼 강남"], "local", "local", "naver_map"),
    ("차경 해방촌 (와인바)", ["차경 해방촌"], "local", "local", "naver_map"),
    ("파스타타타 을지로 (맛집)", ["파스타타타 을지로"], "local", "local", "naver_map"),
    ("양은이네 신대방삼거리역직영점", ["양은이네 신대방삼거리역직영점"], "local", "local", "naver_map"),
    ("런던베이글뮤지엄 안국 (카페)", ["런던베이글뮤지엄 안국"], "local", "local", "naver_map"),
    ("노티드 청담 (디저트)", ["노티드 청담"], "local", "local", "naver_map"),
    ("토리든 다이브인 세럼 (화장품)", ["토리든 다이브인 세럼"], "shop", "cosmetics", "oliveyoung"),
    ("라운드랩 자작나무 토너", ["라운드랩 자작나무 수분 토너"], "shop", "cosmetics", "unknown"),
    ("마뗑킴 가디건 (패션)", ["마뗑킴 라운드 가디건"], "web", "fashion", "unknown"),
    ("무신사 스탠다드 옥스포드 셔츠", ["무신사 스탠다드 옥스포드 셔츠"], "shop", "fashion", "musinsa"),
    ("탐사수 2L 12개 (쿠팡)", ["탐사수 2L 12개"], "shop", "coupang", "coupang"),
    ("다우니 실내건조 섬유유연제", ["다우니 실내건조 섬유유연제"], "shop", "coupang", "coupang"),
    ("로지텍 MX 마스터 3S", ["로지텍 MX 마스터 3S"], "shop", "electronics", "unknown"),
    ("소니 WH-1000XM5 헤드폰", ["소니 WH-1000XM5"], "web", "electronics", "unknown"),
    ("데이비드 호크니 전시 서울", ["데이비드 호크니 전시 서울"], "web", "event_booking", "unknown"),
    ("서울재즈페스티벌 2025", ["서울재즈페스티벌 2025"], "web", "event_booking", "unknown"),
    ("제주도 가볼만한 곳 추천 (큐레이션)", ["제주도 가볼만한 곳 추천"], "blog", "general", "unknown"),
    ("2025 가성비 게이밍 노트북 추천", ["2025 가성비 게이밍 노트북 추천"], "blog", "general", "unknown"),
    ("발더스게이트3 공략 (정보)", ["발더스게이트3 공략"], "web", "web", "unknown"),
    ("리치몬드호텔 야마가타 (해외호텔)", ["리치몬드호텔 야마가타 에키마에"], "web", "event_booking", "unknown"),
]

_BUCKET = {  # provider → bucket (보고용, tool 내부 _bucket 과 동일 분류)
    "naver_map": "primary_action", "catchtable": "primary_action", "coupang": "primary_action",
    "smartstore": "primary_action", "oliveyoung": "primary_action", "musinsa": "primary_action",
    "29cm": "primary_action", "wconcept": "primary_action", "zigzag": "primary_action",
    "naver_shopping": "primary_action", "openmarket": "primary_action",
    "official": "official", "info": "reference", "social": "reference", "site": "reference",
    "visible_url": "observed", "original_url": "observed",
}


async def run_one(tool: ResourceFinderTool, case: tuple, sem: asyncio.Semaphore) -> dict:
    label, queries, category, profile, source = case
    payload = ResourceFinderInput(
        queries=queries, category=category, rank_profile=profile, source_app=source
    )
    async with sem:
        try:
            out, usage = await tool.run(payload)
        except Exception as exc:  # noqa: BLE001
            return {"label": label, "error": f"{type(exc).__name__}: {exc}"}
    # reference_entities[i] 는 ranked_urls[i] 와 동순. per-URL usefulness(="딱 맞아요" 신호)를
    # 붙여 per-URL judge 전환 후 뱃지(usefulness==5)가 케이스당 몇 장 켜지는지 측정한다.
    per_url_useful = [json.loads(s).get("usefulness") for s in out.reference_entities]
    badge_count = sum(1 for u in per_url_useful if u == 5)
    return {
        "label": label,
        "input": {"queries": queries, "category": category,
                  "rank_profile": profile, "source_app": source},
        "useful": out.useful,
        "usefulness": out.usefulness,
        "badge_count": badge_count,  # usefulness==5 인 링크 수("딱 맞아요" 점등 수)
        "comment": out.comment,
        "ranked": [
            {"rank": i + 1, "provider": r.provider,
             "bucket": _BUCKET.get(r.provider, "reference"),
             "role": r.role, "label": r.label, "title": r.title, "url": r.url,
             "usefulness": per_url_useful[i] if i < len(per_url_useful) else None}
            for i, r in enumerate(out.ranked_urls)
        ],
    }


async def main() -> None:
    tool = ResourceFinderTool()
    sem = asyncio.Semaphore(5)
    results = await asyncio.gather(*(run_one(tool, c, sem) for c in CASES))
    OUT.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {OUT} ({len(results)} cases)")
    for r in results:
        if "error" in r:
            print(f"\n[{r['label']}] ⚠️ {r['error']}")
            continue
        buckets = "+".join(x["bucket"][:4] for x in r["ranked"]) or "EMPTY"
        print(f"\n[{r['label']}] useful={r['useful']} u={r['usefulness']} "
              f"badges={r['badge_count']} buckets={buckets}")
        for x in r["ranked"]:
            u = x.get("usefulness")
            tag = " ⭐딱맞아요" if u == 5 else (f" (u={u})" if u else "")
            print(f"  {x['rank']}. [{x['provider']}] {x['label']} — {x['url'][:70]}{tag}")


if __name__ == "__main__":
    asyncio.run(main())
