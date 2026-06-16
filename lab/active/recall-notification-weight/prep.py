"""능동 회수 알림 "무게 판정" 실험 — 데이터 추출·정규화 (공유 모듈).

질문(부모가 결정): 일정/마감의 "무게"(→알림 스케줄 강도)를 정할 때, 기존 importance(1~5)만으로
충분한가, 아니면 LLM 의미판단이 실질적 추가가치를 주는가?

이 모듈은 LLM/규칙 양쪽이 공유하는 입력을 만든다:
  - intent_instances.jsonl 에서 payload 에 deadline|date|end_date 가 있는 건만 추출
  - mochi_item_id 로 mochi_items.jsonl 을 조인 → importance 부착
  - 오늘=2026-06-15 기준 days_until(마감까지 남은 일수) 계산

스키마는 추측 금지 — 두 jsonl 의 실제 키로 확인했다:
  intent_instances: id, mochi_item_id, intent_type, payload{title, deadline|date|end_date, ...}, ...
  mochi_items:      id, importance, category, summary, ...  (importance 는 여기에만 있음)

날짜 포맷은 데이터에 여러 형태가 섞여 있어(date-only / "YYYY-MM-DD HH:MM" / ISO+tz) 관용 파싱한다.
"""
from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path

# 오늘 기준 (부모 지시: 2026-06-15)
TODAY = date(2026, 6, 15)

LAB_ROOT = Path(__file__).parent
DUMP_DIR = LAB_ROOT.parent.parent / "data" / "recall-dump"
INTENT_PATH = DUMP_DIR / "intent_instances.jsonl"
ITEMS_PATH = DUMP_DIR / "mochi_items.jsonl"

DATE_KEYS = ("deadline", "date", "end_date")


def _read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def _parse_to_date(raw: str) -> date | None:
    """데이터에 섞인 여러 날짜 포맷에서 날짜만 뽑는다.

    관찰된 형태: '2026-06-28', '2026-06-14 23:59', '2026-06-18T13:00:00',
                '2026-06-24 19:00:00+09:00', '2026-06-22 23:59:59'
    날짜(앞 10자, YYYY-MM-DD)만 신뢰해 일수 계산에 쓴다 (시각·tz 는 무게 판정에 무관).
    """
    if not raw or not isinstance(raw, str):
        return None
    head = raw.strip()[:10]
    try:
        return datetime.strptime(head, "%Y-%m-%d").date()
    except ValueError:
        return None


def load_cases() -> list[dict]:
    """무게 판정 대상 건 목록. 각 건:
    {key, mochi_item_id, intent_type, title, raw_date, due_date(iso|None),
     days_until(int|None), importance(int|None), category, summary, is_future}
    """
    items = {it["id"]: it for it in _read_jsonl(ITEMS_PATH)}

    cases: list[dict] = []
    for inst in _read_jsonl(INTENT_PATH):
        payload = inst.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        raw_date = None
        used_key = None
        for k in DATE_KEYS:
            if k in payload and payload[k]:
                raw_date = payload[k]
                used_key = k
                break
        if raw_date is None:
            continue

        item = items.get(inst["mochi_item_id"]) or {}
        due = _parse_to_date(raw_date)
        days_until = (due - TODAY).days if due else None

        cases.append(
            {
                # 식별: 같은 title 이 중복 들어있어 instance id 로 고유키
                "key": inst["id"][:8],
                "mochi_item_id": inst["mochi_item_id"][:8],
                "intent_type": inst.get("intent_type"),
                "title": (payload.get("title") or "").strip(),
                "date_key": used_key,
                "raw_date": raw_date,
                "due_date": due.isoformat() if due else None,
                "days_until": days_until,
                "importance": item.get("importance"),
                "category": item.get("category"),
                "summary": (item.get("summary") or "")[:120],
                "is_future": (days_until is not None and days_until >= 0),
            }
        )
    return cases


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8")
    cases = load_cases()
    fut = [c for c in cases if c["is_future"]]
    print(f"총 {len(cases)}건 추출 (deadline|date|end_date 보유), 미래(>= today) {len(fut)}건\n")
    print(f"{'imp':>3} {'days':>5} {'itype':9} {'date':12} title")
    for c in sorted(cases, key=lambda x: (x["days_until"] if x["days_until"] is not None else 999)):
        print(
            f"{str(c['importance']):>3} {str(c['days_until']):>5} "
            f"{(c['intent_type'] or ''):9} {(c['due_date'] or '?'):12} {c['title'][:42]}"
        )
