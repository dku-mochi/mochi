"""판정기 민감도 ablation — sufficient 판정이 false 도 주는가(아니면 항상 true 인가).

본 실험(youtube_enrich_bench)이 sufficient 100% 를 냈는데, 데이터셋이 전부 인기 영상
(설명 풍부)이라 편향됐을 수 있다. 판정기가 무조건 true 를 주는 게 아님을 보이려면
설명이 빈/모호한 합성 케이스에서 false 가 나와야 한다. 그걸 확인한다.

실행: GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
        uv run --directory mochi-backend python lab/active/youtube-enrich/ablation_sufficiency.py
"""

from __future__ import annotations

import sys

sys.path.insert(0, "/Users/jun/Downloads/mochi/lab/active/youtube-enrich")
from youtube_enrich_bench import _analyze_sync  # noqa: E402

# 합성 메타 — 실사용에서 흔한 "빈약" 패턴들
CASES = [
    {"label": "명확제목+설명없음", "title": "iPhone 16 Pro Review",
     "channel": "TechGuy", "length_seconds": 600, "has_captions": True, "keywords": [], "description": ""},
    {"label": "모호제목+설명없음", "title": "브이로그",
     "channel": "홍길동", "length_seconds": 420, "has_captions": False, "keywords": [], "description": ""},
    {"label": "해시태그만", "title": "오늘 ㅎㅎ",
     "channel": "abc", "length_seconds": 15, "has_captions": False, "keywords": [], "description": "#daily #vlog #fyp"},
    {"label": "무제", "title": "video",
     "channel": "user123", "length_seconds": 90, "has_captions": False, "keywords": [], "description": ""},
    {"label": "제목만_운동", "title": "10분 아침 스트레칭 루틴",
     "channel": "FitChannel", "length_seconds": 600, "has_captions": False, "keywords": [], "description": ""},
]

if __name__ == "__main__":
    print("▶ 판정기 민감도 ablation\n")
    n_false = 0
    for c in CASES:
        a = _analyze_sync(c)
        if not a["sufficient"]:
            n_false += 1
        print(f"[{c['label']}] title={c['title']!r} desc={len(c['description'])}자")
        print(f"   → intent={a['intent']}  sufficient={a['sufficient']}  conf={a.get('confidence')}")
        print(f"   summary: {a['summary']}")
        if not a["sufficient"]:
            print(f"   fallback_reason: {a.get('fallback_reason')}")
        print()
    print(f"= false(=fallback 필요) 판정: {n_false}/{len(CASES)} "
          f"→ {'판정기 작동(0보다 큼)' if n_false else '⚠️ 전부 true: 판정기 관대 의심'}")
