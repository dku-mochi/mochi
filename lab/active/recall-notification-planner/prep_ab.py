"""A/B 실험용 입력 빌더 — gold 7 (prep.py 재사용) + 실데이터 active 항목 전체.

부모 질문: "강한 하네스 프롬프트 + 이전 맥락 주입(sliding window)" 이
알림 플래너 LLM 의 비결정성을 줄이고 gold(사용자 직관)에 맞는 계획을 만드는가?

두 조건 비교 (ab_planner.py 가 실행):
  (A) baseline   = 약한 프롬프트 + 독립 호출(이전 결정 모름)
  (B) 제안       = 강한 규칙 프롬프트 + 이전 맥락 주입(직전까지 결정된 "예정 알림 목록" 누적)

이 모듈이 하는 일:
  - load_real_active_cases(): recall-dump 의 active 항목 전체에서
      · todo/schedule 전부 (마감/일정 있는 것 우선)
      · memo 중 "지속 의도(continuing)/위시(wish)" 후보 큐레이션
    를 뽑아 created_at 시간순으로 정렬.
  - build_dataset(): gold 7 + 실데이터 active 를 합쳐 시간순 큐를 만든다.
  - two_orderings(): 같은 set 을 두 입력 순서로(시간순 / 역+셔플) 만들어
    "입력 순서 민감도(비결정성)" 를 측정하게 한다.

gold 7 (G1~G7) 와 활동 히스토그램·죽은시간·CAPTURE_NOW 는 기존 prep.py 를 그대로 import.
"""
from __future__ import annotations

import json
import random
from datetime import date, datetime
from pathlib import Path

from prep import (  # noqa: E402  (기존 자산 재사용)
    ACTIVITY_DESC,
    ACTIVITY_HISTOGRAM,
    CAPTURE_NOW,
    DEAD_HOURS,
    GOLD_CASES,
    TODAY,
    _parse_to_date,
    _read_jsonl,
    days_until,
)

LAB_ROOT = Path(__file__).parent
DUMP_DIR = LAB_ROOT.parent.parent / "data" / "recall-dump"
INTENT_PATH = DUMP_DIR / "intent_instances.jsonl"
ITEMS_PATH = DUMP_DIR / "mochi_items.jsonl"

OWNER = "71503fa8-d478-4a2c-b2ac-3d29b0498ccd"  # recall-dump 의 메인 owner

# 현재시각: 부모 지시 "2026-06-15 23:30 기준". 밤 활발(22~03) 시간대.
NOW_DT = datetime(2026, 6, 15, 23, 30)


# memo 중 "지속 의도/위시" 로 처리할 가치가 있는 후보 (사람이 큐레이션).
# 단순 OCR 더미·중복 기록(아이폰 홈화면·사이트 정보 확인·종목 시세 캡처 중복)은 제외 —
# 알림 계획을 짤 의미가 있는 것만. created_at 으로 정렬되므로 첫 등장만 남긴다.
MEMO_TITLE_WHITELIST = {
    # 지속 의도(continuing) — 마감 없으나 손 놓으면 안 되는 것
    "친구들과의 모임 계획 (벼락부자 4)",
    "박세현 님 카카오톡 알림 (SW중심대학 디지털 경진대회)",
    "스탬플리 앱 활용 및 허니콤보 혜택 확인",
    "양은이네 신대방삼거리역직영점",
    "5월 실현수익 내역 확인",
    # 위시(wish) — 향후 구매 고려
    "로프리(Lofree) EDGE 키보드 20% 할인",
    "유니클로 추천 아이템(셔츠 및 와이드 진)",
    "무신사 스탠다드 헨리 넥 티셔츠 [미디엄 그레이]",
    "브론슨 1936 Lot 101J Cowboys Jacket 구매 고려",
    "노운 henley neck t-shirts (melange gray) 구매 고민",
    "무신사 무진장 26 여름 블랙프라이데이 일정 확인",
    "SOTSU 포터블 모니터 (FlipAction TOUCH 14, GO 14)",
}


def _get(payload: dict, *keys: str):
    for k in keys:
        v = payload.get(k)
        if v:
            return v
    return None


def load_real_active_cases() -> list[dict]:
    """recall-dump active 항목 전체에서 알림 계획 대상 추출 (gold 없음, 정성평가).

    포함: todo/schedule 전부 + memo 화이트리스트. created_at 시간순.
    """
    items = {it["id"]: it for it in _read_jsonl(ITEMS_PATH)}
    rows = [
        r
        for r in _read_jsonl(INTENT_PATH)
        if r.get("owner_id") == OWNER and r.get("lifecycle_kind") == "active"
    ]
    rows.sort(key=lambda r: r.get("created_at", ""))

    out: list[dict] = []
    seen_titles: set[str] = set()
    for r in rows:
        itype = r.get("intent_type")
        p = r.get("payload") or {}
        if not isinstance(p, dict):
            continue
        title = (_get(p, "title") or r.get("label") or "").strip()
        if not title or title in seen_titles:
            continue

        keep = False
        real_tag = ""
        if itype in ("todo", "schedule"):
            keep = True
            raw_date = _get(p, "deadline", "date", "end_date", "start_date")
            real_tag = "real_deadline" if raw_date else "no_deadline"
        elif itype == "memo" and title in MEMO_TITLE_WHITELIST:
            keep = True
            raw_date = None
            real_tag = "continuing_or_wish"
        else:
            continue
        if not keep:
            continue

        seen_titles.add(title)
        it = items.get(r["mochi_item_id"]) or {}
        raw_date = _get(p, "deadline", "date", "end_date", "start_date")
        date_key = (
            "deadline"
            if p.get("deadline")
            else "date"
            if p.get("date")
            else "end_date"
            if p.get("end_date")
            else None
        )
        out.append(
            {
                "key": f"R-{itype}-{r['id'][:6]}",
                "title": title,
                "intent_type": itype,
                "date_key": date_key,
                "raw_date": raw_date,
                "category": it.get("category"),
                "importance": it.get("importance"),
                "summary": (it.get("summary") or "")[:140],
                "created_at": r.get("created_at"),
                "real_tag": real_tag,
                "gold": None,
            }
        )
    return out


def _gold_created_at() -> dict[str, str]:
    """gold 7 의 시간순 위치(맥락주입 누적 순서)를 위해 created_at 을 합성 부여.
    부모 지시: gold 합성 케이스를 실데이터와 '섞어라'. 저장시점은 실데이터 범위 내로 분산.
    """
    base = {
        "G1-toeic": "2026-06-11T05:00:00",   # 토익(먼 시험)
        "G2-minsu": "2026-06-15T13:00:00",   # 내일 약속 (직전 저장)
        "G3-contest": "2026-06-12T14:00:00",
        "G4-essay": "2026-06-15T10:00:00",   # 오늘 마감 과제
        "G5-finals": "2026-06-13T15:00:00",
        "G6-callmom": "2026-06-10T22:00:00",
        "G7-coat": "2026-06-14T16:00:00",
    }
    return base


def build_dataset() -> list[dict]:
    """gold 7 + 실데이터 active 를 합쳐 created_at 시간순 큐로 반환."""
    gold_ts = _gold_created_at()
    gold = []
    for c in GOLD_CASES:
        c2 = dict(c)
        c2["created_at"] = gold_ts.get(c["key"], "2026-06-15T12:00:00")
        c2["real_tag"] = "gold"
        c2.setdefault("summary", "")
        gold.append(c2)

    real = load_real_active_cases()
    allc = gold + real
    allc.sort(key=lambda c: c.get("created_at", ""))
    return allc


def two_orderings(dataset: list[dict]) -> dict[str, list[dict]]:
    """비결정성 측정용 두 입력 순서.
    - chrono: created_at 시간순(자연스러운 도착순; B 맥락주입의 기본 가정)
    - shuffled: 고정 시드 셔플(같은 set, 다른 순서) — 순서 민감도 노출
    """
    chrono = sorted(dataset, key=lambda c: c.get("created_at", ""))
    shuffled = list(dataset)
    random.Random(20260615).shuffle(shuffled)
    return {"chrono": chrono, "shuffled": shuffled}


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8")
    ds = build_dataset()
    gold_n = sum(1 for c in ds if c["real_tag"] == "gold")
    print(f"총 {len(ds)}케이스 (gold {gold_n} + 실데이터 {len(ds) - gold_n})")
    print(f"NOW={NOW_DT.isoformat()}  TODAY={TODAY.isoformat()}\n")
    print(f"{'created_at':20} {'key':22} {'itype':9} {'days':>5} {'tag':18} title")
    for c in ds:
        du = days_until(c.get("raw_date"))
        print(
            f"{str(c.get('created_at'))[:19]:20} {c['key']:22} "
            f"{(c['intent_type'] or ''):9} {str(du):>5} {c['real_tag']:18} {c['title'][:36]}"
        )
    from collections import Counter

    print("\nintent_type:", Counter(c["intent_type"] for c in ds))
    print("real_tag:", Counter(c["real_tag"] for c in ds))
    print(f"죽은시간(회피): {sorted(DEAD_HOURS)}")
