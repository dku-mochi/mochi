"""알림 플래너 실험 — 입력 케이스 정의 (gold 합성 7건 + 실데이터 보강).

핵심 질문(부모가 결정): 생성 시점에 flash-lite 가 item 을 보고 사용자 직관에 맞는
"알림 계획"(시점들·주기·상대시간)을 짜내는가, 그리고 안정적인가(3회 반복 일관성).

이 모듈은 LLM 입력이 되는 케이스 리스트를 만든다. 두 출처:
  (A) GOLD_CASES — 사용자가 직접 준 정답 7건 (합성). gold 계획을 함께 인코딩.
  (B) load_real_cases() — recall-dump 실데이터에서 위 유형 진짜 케이스 추출 (gold 없음, 정성평가).

"알림 계획의 어휘 5종" (LLM 도 이 어휘로 trigger 를 표현하게 강제):
  - 절대시각 다단:  ["D-30","D-14","D-7","D-3","D-1"] 류 — 마감/일정일 기준 며칠 전
  - 단발 전날:      ["D-1"]
  - 상대시간(마감-Nh): ["마감-2h"] — deadline 기준 N시간 전
  - 상대시간(저장+Nh): ["저장+2h"] — 캡처 시점 기준 N시간 뒤
  - 주기넛지(마감없음): ["every-3d-x3"] — N일마다 총 x회
  - 가벼운 주기(위시):  ["every-10d-x3"]

개인 컨텍스트(사용자 요청, 모든 입력에 포함):
  owner 활동 시간대(KST): 밤 22~새벽3시 + 낮 13~17시 활발, 6~10시 완전 공백(수면).
  → LLM 이 time_hint 를 정할 때 죽은 시간(6~10시) 회피 / 활동시간대 배치 하는지 본다.
"""
from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path

# 오늘 기준 (직전 실험과 동일, 부모 지시 흐름)
TODAY = date(2026, 6, 15)
# "저장 시점"(캡처)의 가정 — #4 과제처럼 상대시간 판단에 필요. 부모 지시: "4h 전 저장→2h 뒤 알림" 예시.
# 오늘 낮 활동시간대(13~17)에 저장했다고 가정 → 19:00 KST (마감 23:59 의 약 5h 전).
CAPTURE_NOW = datetime(2026, 6, 15, 19, 0)  # KST naive

LAB_ROOT = Path(__file__).parent
DUMP_DIR = LAB_ROOT.parent.parent / "data" / "recall-dump"
INTENT_PATH = DUMP_DIR / "intent_instances.jsonl"
ITEMS_PATH = DUMP_DIR / "mochi_items.jsonl"

# 개인 활동 히스토그램 (KST 24시간, 상대 활동량 0~3). 사용자 요청 시간대를 그대로 인코딩.
#   22~03시: 활발(3),  13~17시: 활발(3),  06~10시: 공백(0, 수면),  나머지: 보통(1)
ACTIVITY_HISTOGRAM = {
    0: 3, 1: 3, 2: 3, 3: 2,   # 새벽 활발 끝물
    4: 1, 5: 1,
    6: 0, 7: 0, 8: 0, 9: 0,   # 완전 공백(수면)
    10: 0,                      # 사용자 명시: "6~10시 완전 공백" → 10 포함 공백
    11: 1, 12: 2,
    13: 3, 14: 3, 15: 3, 16: 3, 17: 3,  # 낮 활발
    18: 2, 19: 2, 20: 2, 21: 2,
    22: 3, 23: 3,             # 밤 활발 시작
}
DEAD_HOURS = {6, 7, 8, 9, 10}  # "죽은 시간" — 여기 배치되면 실패

ACTIVITY_DESC = (
    "이 사용자의 평소 활동 시간대(KST): 밤 22시~새벽 3시, 낮 13~17시에 가장 활발하다. "
    "오전 6~10시는 완전 공백(수면 중)이라 이 시간대 알림은 무조건 피해야 한다."
)


# ── (A) GOLD 합성 7건 ────────────────────────────────────────────────
# gold 는 LLM 에 주지 않는다(입력엔 채점용 필드 제외). 채점 시에만 사용.
GOLD_CASES = [
    {
        "key": "G1-toeic",
        "title": "토익 시험 응시",
        "intent_type": "schedule",
        "date_key": "date",
        "raw_date": "2026-06-28",
        "category": "학업",
        "importance": 5,
        "gold": {
            "weight": "heavy",
            "plan_type": "절대시각 다단 + 전날",
            "note": "한 달 전부터 주기적 + 전날 1회. 무거움. D-1 포함 필수.",
            "expect_triggers_kind": "absolute_multistage",  # D-n 다단
            "expect_has_D1": True,
            "expect_periodic": False,
        },
    },
    {
        "key": "G2-minsu",
        "title": "민수와 만남",
        "intent_type": "schedule",
        "date_key": "date",
        "raw_date": "2026-06-16",  # 내일
        "category": "일상",
        "importance": 3,
        "gold": {
            "weight": "light",
            "plan_type": "단발 전날",
            "note": "단발: 전날 1회. (D-1 한 번)",
            "expect_triggers_kind": "single_D1",
            "expect_has_D1": True,
            "expect_periodic": False,
            "expect_max_count": 1,
        },
    },
    {
        "key": "G3-contest",
        "title": "OO 대회 본선",
        "intent_type": "schedule",
        "date_key": "date",
        "raw_date": "2026-07-20",  # 먼
        "category": "학업/공모전",
        "importance": 4,
        "gold": {
            "weight": "heavy",
            "plan_type": "절대시각 다단",
            "note": "토익과 동일, 무거움. 먼 일정이라 일찍부터 다단.",
            "expect_triggers_kind": "absolute_multistage",
            "expect_has_D1": True,
            "expect_periodic": False,
        },
    },
    {
        "key": "G4-essay",
        "title": "과제 Final Essay 제출",
        "intent_type": "todo",
        "date_key": "deadline",
        "raw_date": "2026-06-15 23:59",  # 오늘 마감
        "category": "학업",
        "importance": 5,
        "gold": {
            "weight": "medium",
            "plan_type": "상대시간(마감-Nh)",
            "note": "마감 몇 시간 전 1회. 저장 시점+개인 활동시간으로 시각 판단. '혹시 제출하셨나요?'",
            "expect_triggers_kind": "relative_before_deadline",  # 마감-Nh 형태
            "expect_has_D1": False,
            "expect_periodic": False,
            "expect_max_count": 2,
        },
    },
    {
        "key": "G5-finals",
        "title": "기말고사",
        "intent_type": "schedule",
        "date_key": "date",
        "raw_date": "2026-06-18",
        "category": "학업",
        "importance": 5,
        "gold": {
            "weight": "heavy",
            "plan_type": "절대시각 다단",
            "note": "토익과 동일, 무거움.",
            "expect_triggers_kind": "absolute_multistage",
            "expect_has_D1": True,
            "expect_periodic": False,
        },
    },
    {
        "key": "G6-callmom",
        "title": "엄마에게 전화하기",
        "intent_type": "todo",
        "date_key": None,
        "raw_date": None,  # deadline 없음
        "category": "일상",
        "importance": 3,
        "gold": {
            "weight": "light",
            "plan_type": "주기 넛지",
            "note": "마감 없음 → ~3일마다 총 2~3회. 스스로 주기 만들어내야.",
            "expect_triggers_kind": "periodic_nudge",
            "expect_has_D1": False,
            "expect_periodic": True,
            "expect_period_days_range": (2, 4),
            "expect_count_range": (2, 3),
        },
    },
    {
        "key": "G7-coat",
        "title": "월급 들어오면 이 코트 사기",
        "intent_type": "memo",
        "date_key": None,
        "raw_date": None,  # deadline 없음
        "category": "쇼핑",
        "importance": 2,
        "gold": {
            "weight": "light",
            "plan_type": "가벼운 주기(위시)",
            "note": "마감 없음 → ~10일마다 총 3회. 가벼운 위시 리마인드.",
            "expect_triggers_kind": "light_periodic",
            "expect_has_D1": False,
            "expect_periodic": True,
            "expect_period_days_range": (7, 14),
            "expect_count_range": (2, 4),
        },
    },
]


# ── (B) 실데이터 보강 ────────────────────────────────────────────────
def _read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def _parse_to_date(raw: str) -> date | None:
    if not raw or not isinstance(raw, str):
        return None
    head = raw.strip()[:10]
    try:
        return datetime.strptime(head, "%Y-%m-%d").date()
    except ValueError:
        return None


# 사람이 고른 실데이터 보강 대상 (gold 유형별 진짜 케이스). instance id prefix 로 지정.
# 탐색 결과 골라낸 것 — 마감없는 지속의도 2 + 위시/쇼핑 2 + 대조용 실제 마감 1.
REAL_TITLE_MATCHES = [
    # 마감 없는 지속 의도 (= G6 엄마전화 유형)
    ("주말 저녁 데이트 약속 조율", "continuing_no_deadline"),
    ("모찌 채팅탭 맞춤형 예시 질문 추가", "continuing_no_deadline"),
    # 위시/쇼핑 (= G7 코트 유형, "향후 구매를 고려")
    ("로프리(Lofree) EDGE 키보드 20% 할인", "wish_shopping"),
    ("유니클로 추천 아이템(셔츠 및 와이드 진)", "wish_shopping"),
    # 대조용: 진짜 마감 있는 과제 (= G4 essay 유형, 상대시간 기대)
    ("나를브랜딩하는취업설계 1분반 기말고사 대체과제 제출", "real_deadline_todo"),
]


def load_real_cases() -> list[dict]:
    """실데이터에서 보강 케이스 추출. gold 없음 (정성 평가용)."""
    items = {it["id"]: it for it in _read_jsonl(ITEMS_PATH)}
    by_title: dict[str, dict] = {}
    for inst in _read_jsonl(INTENT_PATH):
        p = inst.get("payload") or {}
        if not isinstance(p, dict):
            continue
        t = (p.get("title") or "").strip()
        if t and t not in by_title:
            by_title[t] = inst  # 첫 등장만 (중복 제거)

    out: list[dict] = []
    for title, tag in REAL_TITLE_MATCHES:
        inst = by_title.get(title)
        if not inst:
            continue
        p = inst["payload"]
        it = items.get(inst["mochi_item_id"]) or {}
        raw_date = p.get("deadline") or p.get("date") or p.get("end_date")
        due = _parse_to_date(raw_date) if raw_date else None
        out.append(
            {
                "key": f"R-{tag}-{inst['id'][:6]}",
                "title": title,
                "intent_type": inst.get("intent_type"),
                "date_key": ("deadline" if p.get("deadline") else "date" if p.get("date") else None),
                "raw_date": raw_date,
                "category": it.get("category"),
                "importance": it.get("importance"),
                "summary": (it.get("summary") or "")[:120],
                "real_tag": tag,
                "gold": None,  # 정성 평가
            }
        )
    return out


def days_until(raw_date: str | None) -> int | None:
    if not raw_date:
        return None
    d = _parse_to_date(raw_date)
    return (d - TODAY).days if d else None


def all_cases() -> list[dict]:
    return GOLD_CASES + load_real_cases()


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8")
    cases = all_cases()
    print(f"총 {len(cases)}케이스 (gold {len(GOLD_CASES)} + 실데이터 {len(cases) - len(GOLD_CASES)})\n")
    print(f"{'key':28} {'itype':9} {'days':>5} {'imp':>3} {'cat':12} title")
    for c in cases:
        du = days_until(c.get("raw_date"))
        print(
            f"{c['key']:28} {(c['intent_type'] or ''):9} {str(du):>5} "
            f"{str(c.get('importance')):>3} {str(c.get('category'))[:12]:12} {c['title'][:36]}"
        )
    print(f"\n활동 히스토그램(시:활동량): {ACTIVITY_HISTOGRAM}")
    print(f"죽은 시간(회피 대상): {sorted(DEAD_HOURS)}")
    print(f"가정 저장시점(#4 상대시간용): {CAPTURE_NOW.isoformat()}")
