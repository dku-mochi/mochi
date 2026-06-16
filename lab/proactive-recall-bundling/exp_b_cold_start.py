"""실험 B — Cold Start.

처음 N(=3/5/10/20/all)개 item 시점에서:
- 묶을 수 있는 주제(member>=2)가 몇 개 나오는가
- 회수 가능(=어떤 multi-member 라벨에 속한) item 비율

"이상적 묶음기" 를 가정하기 위해 ground-truth theme 기준으로 측정한다
(실험 A 에서 LLM 묶음 품질은 별도로 봤으니, 여기선 '데이터에 묶을 거리가
언제부터 생기나' 라는 구조적 질문에 집중). theme 이 없는 item 은 묶이지 않는
싱글톤으로 간주(보수적).
"""

from __future__ import annotations

import json
import os
from collections import Counter

from common import load_items, theme_of

OUT = os.path.join(os.path.dirname(__file__), "exp_b_results.json")


def run() -> dict:
    items = load_items()
    rows = []
    for n in [3, 5, 10, 20, 30, 50, len(items)]:
        prefix = items[:n]
        theme_counts = Counter(theme_of(i) for i in prefix if theme_of(i))
        multi_themes = {t: c for t, c in theme_counts.items() if c >= 2}
        recallable = sum(c for c in multi_themes.values())
        rows.append(
            {
                "at_n_items": n,
                "n_bundles": len(multi_themes),  # member>=2 주제 수
                "n_recallable_items": recallable,
                "recallable_ratio": round(recallable / n, 2),
                "bundles": {t: multi_themes[t] for t in sorted(multi_themes)},
            }
        )
    return {"note": "ground-truth theme 기준 (이상적 묶음기 가정)", "timeline": rows}


if __name__ == "__main__":
    result = run()
    with open(OUT, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"wrote {OUT}")
    for r in result["timeline"]:
        print(
            f"  @{r['at_n_items']:3d} items: bundles={r['n_bundles']} "
            f"recallable={r['n_recallable_items']} ({r['recallable_ratio']:.0%}) {r['bundles']}"
        )
