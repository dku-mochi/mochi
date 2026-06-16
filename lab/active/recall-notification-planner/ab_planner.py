"""A/B 알림 플래너 — 강프롬프트+맥락주입(B) vs 약프롬프트+독립호출(A).

부모 질문: "강한 하네스 프롬프트 + 이전 맥락 주입(sliding window)" 이
LLM 의 비결정성을 줄이고 gold(사용자 직관) 에 맞는 계획을 만드는가?

조건:
  (A) baseline = WEAK_SYSTEM + 독립 호출(이전 결정 모름)
  (B) 제안     = STRONG_SYSTEM + 맥락 주입(직전까지 결정된 "예정 알림 목록" 누적)

비결정성 측정: 각 조건을 입력 순서 2가지(chrono / shuffled)로 돌려, 같은 item 의
계획(날짜·time·repeat 유무)이 순서에 따라 얼마나 바뀌나(변동율). B 가 A 보다 안정적인지가 1순위.

콜 수 (사전 로그):
  4 run = A×{chrono,shuffled} + B×{chrono,shuffled}.
  A 는 케이스당 1콜(독립). B 도 케이스당 1콜(맥락 주입, 누적은 프롬프트 텍스트로만).
  N케이스=38 → 38×4 = 152콜 (flash-lite, temp=0, JSON 구조화 출력).
  DRY_RUN=1 로 콜 수만 확인 가능.

실행 (repo 루트에서, ADC 필요):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\
    python ../lab/active/recall-notification-planner/ab_planner.py

결과: results/ab_YYYYMMDD_HHMMSS.json (+ ab_latest.json). 콘솔에 비교표 요약.
"""
from __future__ import annotations

import json
import os
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from prep_ab import (  # noqa: E402
    ACTIVITY_DESC,
    ACTIVITY_HISTOGRAM,
    DEAD_HOURS,
    NOW_DT,
    TODAY,
    build_dataset,
    days_until,
    two_orderings,
)
from strong_prompt import STRONG_SYSTEM, WEAK_SYSTEM  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"
RESULTS_DIR = Path(__file__).parent / "results"

# 맥락 주입에서 최근 저장 N개를 비슷한 기록 근사로 보여줄 때의 상한
RECENT_N = 6


def _hist_str() -> str:
    return ", ".join(f"{h:02d}:{v}" for h, v in sorted(ACTIVITY_HISTOGRAM.items()))


# ── 출력 스키마 (JSON: notifications + reasoning) ─────────────────────
def schema_dict() -> dict:
    return {
        "type": "object",
        "properties": {
            "notifications": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "date": {"type": "string", "description": "YYYY-MM-DD KST"},
                        "time": {"type": "string", "description": "HH:MM KST 24h"},
                        "content": {"type": "string", "description": "한국어 한 줄"},
                        "repeat_rule": {
                            "type": "string",
                            "description": "주기 넛지일 때만, 자연어 (예: '3일마다 총 3회')",
                        },
                    },
                    "required": ["date", "time", "content"],
                },
            },
            "reasoning": {"type": "string"},
        },
        "required": ["notifications", "reasoning"],
    }


# ── 입력 프롬프트 구성 ──────────────────────────────────────────────
def _item_block(c: dict) -> str:
    du = days_until(c.get("raw_date"))
    if c.get("raw_date"):
        date_line = f"- date/deadline: {c['date_key']}={c['raw_date']} (days_until={du})\n"
    else:
        date_line = "- date/deadline: NONE (no due date set)\n"
    summary_line = f"- summary: {c['summary']}\n" if c.get("summary") else ""
    return (
        f"- title: {c['title']}\n"
        f"- intent_type: {c['intent_type']}\n"
        f"- category: {c.get('category')}\n"
        f"- importance(1-5, advisory): {c.get('importance')}\n"
        f"{date_line}{summary_line}"
    )


def user_prompt_A(c: dict) -> str:
    """약한 baseline: 항목만, 컨텍스트 거의 없음 (독립 호출)."""
    return (
        f"Today is {TODAY.isoformat()}. The user just saved this item:\n"
        f"{_item_block(c)}"
        "Plan reminder notifications for it. Reply as JSON {notifications, reasoning}."
    )


def _scheduled_context(scheduled: list[dict]) -> str:
    """직전까지 결정된 '예정 알림 목록' 을 시간순으로 누적해 텍스트화 (B 의 핵심)."""
    if not scheduled:
        return "(none yet -- this is one of the first items)"
    # 미래(>= 오늘) 알림만, 날짜순. 너무 길지 않게 상한.
    fut = sorted(scheduled, key=lambda n: (n.get("date", ""), n.get("time", "")))
    lines = []
    for n in fut[:40]:
        rr = f" [repeat: {n['repeat_rule']}]" if n.get("repeat_rule") else ""
        lines.append(f"  {n.get('date')} {n.get('time')} <{n.get('src_title', '')[:24]}> "
                     f"{n.get('content', '')[:40]}{rr}")
    return "\n".join(lines)


def _recent_context(recent: list[dict]) -> str:
    if not recent:
        return "(none)"
    return "\n".join(
        f"  [{r['intent_type']}/{r.get('category')}] {r['title'][:40]}" for r in recent[-RECENT_N:]
    )


def user_prompt_B(c: dict, scheduled: list[dict], recent: list[dict]) -> str:
    """강한 조건: 현재시각 + 활동 히스토그램 + 직전까지 예정 알림(누적) + 최근 저장 + 클릭로그 슬롯."""
    return (
        f"NOW: {NOW_DT.isoformat()} KST. The user just saved a new item.\n\n"
        f"[NEW ITEM]\n{_item_block(c)}\n"
        f"[USER ACTIVITY HISTOGRAM] (hour:activity 0..3; 0=asleep/dead, avoid). "
        f"{ACTIVITY_DESC}\n  {_hist_str()}\n\n"
        f"[ALREADY-SCHEDULED REMINDERS so far] (time-ordered running plan across all items. "
        f"Use this to BUNDLE onto existing days, avoid duplicates, and stay under the daily cap):\n"
        f"{_scheduled_context(scheduled)}\n\n"
        f"[RECENT SAVES] (approximation of 'similar records'; vector recall excluded):\n"
        f"{_recent_context(recent)}\n\n"
        f"[PAST NOTIFICATION CLICK LOG]: none (cold start -- no click history available).\n\n"
        f"Plan the full lifetime of reminders for THIS new item now, consistent with the running plan."
    )


# ── LLM ─────────────────────────────────────────────────────────────
def client():
    from google import genai

    return genai.Client(
        vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location=LOCATION
    )


def call(cli, system: str, prompt: str) -> dict:
    from google.genai import types

    resp = cli.models.generate_content(
        model=MODEL,
        contents=[types.Content(role="user", parts=[types.Part.from_text(text=prompt)])],
        config=types.GenerateContentConfig(
            system_instruction=system,
            response_mime_type="application/json",
            response_schema=schema_dict(),
            temperature=0.0,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
        ),
    )
    return json.loads(resp.text)


# ── 한 run 실행 ─────────────────────────────────────────────────────
def run_A(cli, ordering: list[dict]) -> dict[str, dict]:
    """약+독립: 각 케이스 단독 호출. key -> plan."""
    out = {}
    for c in ordering:
        try:
            res = call(cli, WEAK_SYSTEM, user_prompt_A(c))
        except Exception as e:  # noqa: BLE001
            res = {"error": str(e)[:200], "notifications": [], "reasoning": ""}
        out[c["key"]] = res
    return out


def run_B(cli, ordering: list[dict]) -> dict[str, dict]:
    """강+맥락주입: 누적 'scheduled' 를 다음 케이스 프롬프트에 주입. key -> plan."""
    out = {}
    scheduled: list[dict] = []  # 누적 예정 알림 (모든 케이스의 결정 합)
    recent: list[dict] = []
    for c in ordering:
        try:
            res = call(cli, STRONG_SYSTEM, user_prompt_B(c, scheduled, recent))
        except Exception as e:  # noqa: BLE001
            res = {"error": str(e)[:200], "notifications": [], "reasoning": ""}
        out[c["key"]] = res
        # 누적: 이 케이스가 만든 알림을 src_title 달아 scheduled 에 추가
        for n in res.get("notifications", []) or []:
            if isinstance(n, dict) and n.get("date"):
                scheduled.append({**n, "src_title": c["title"]})
        recent.append(c)
    return out


# ── 분석/채점 ───────────────────────────────────────────────────────
def _plan_signature(res: dict) -> tuple:
    """비결정성 비교용 정규화 시그니처: (정렬된 (date,time) 집합, repeat 유무, n)."""
    notes = res.get("notifications", []) or []
    dts = sorted((str(n.get("date", "")), str(n.get("time", ""))) for n in notes if isinstance(n, dict))
    has_repeat = any(n.get("repeat_rule") for n in notes if isinstance(n, dict))
    return (tuple(dts), has_repeat, len(notes))


def _dates_set(res: dict) -> set:
    return {str(n.get("date", "")) for n in (res.get("notifications") or []) if isinstance(n, dict)}


def nondeterminism(chrono: dict, shuffled: dict) -> dict:
    """같은 key 의 plan 이 두 순서에서 얼마나 바뀌나."""
    keys = [k for k in chrono if k in shuffled]
    exact_same = 0          # 시그니처 완전일치
    dateset_same = 0        # 알림 '날짜 집합' 일치 (시각 무시)
    count_same = 0          # 알림 개수 일치
    jaccard_sum = 0.0
    per_case = {}
    for k in keys:
        sc, ss = chrono[k], shuffled[k]
        sig_c, sig_s = _plan_signature(sc), _plan_signature(ss)
        ds_c, ds_s = _dates_set(sc), _dates_set(ss)
        exact = sig_c == sig_s
        same_dates = ds_c == ds_s
        same_count = sig_c[2] == sig_s[2]
        union = ds_c | ds_s
        jac = (len(ds_c & ds_s) / len(union)) if union else 1.0
        exact_same += exact
        dateset_same += same_dates
        count_same += same_count
        jaccard_sum += jac
        per_case[k] = {
            "exact": exact,
            "same_dates": same_dates,
            "n_chrono": sig_c[2],
            "n_shuffled": sig_s[2],
            "date_jaccard": round(jac, 2),
        }
    n = len(keys)
    return {
        "n_cases": n,
        "exact_match_rate": round(exact_same / n, 3) if n else 0,
        "dateset_match_rate": round(dateset_same / n, 3) if n else 0,
        "count_match_rate": round(count_same / n, 3) if n else 0,
        "mean_date_jaccard": round(jaccard_sum / n, 3) if n else 0,
        "per_case": per_case,
    }


def _parse_d(s: str) -> date | None:
    try:
        return datetime.strptime(str(s)[:10], "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None


def _parse_t(s: str) -> int | None:
    try:
        return int(str(s).split(":")[0])
    except (ValueError, IndexError, TypeError):
        return None


def cap_and_bundling(plan: dict, dataset: list[dict]) -> dict:
    """하루 cap 위반·죽은시간 배치·묶기(같은 날 여러 src 합산) 분석. 한 run 전체 기준."""
    by_day: dict[str, list[dict]] = defaultdict(list)
    dead_hits = 0
    total_notes = 0
    for k, res in plan.items():
        for n in res.get("notifications", []) or []:
            if not isinstance(n, dict) or not n.get("date"):
                continue
            total_notes += 1
            by_day[str(n["date"])].append({"src": k, **n})
            h = _parse_t(n.get("time"))
            if h in DEAD_HOURS:
                dead_hits += 1
    cap_viol_2 = sum(1 for v in by_day.values() if len(v) > 2)
    cap_viol_3 = sum(1 for v in by_day.values() if len(v) > 3)
    # 묶기 관측: 같은 날 서로 다른 src 가 함께 있는 날 수 (묶을 기회)
    multi_src_days = sum(1 for v in by_day.values() if len({x["src"] for x in v}) >= 2)
    return {
        "total_notifications": total_notes,
        "days_with_notifications": len(by_day),
        "max_per_day": max((len(v) for v in by_day.values()), default=0),
        "days_over_2": cap_viol_2,
        "days_over_3": cap_viol_3,
        "dead_hour_placements": dead_hits,
        "multi_source_days": multi_src_days,
    }


# gold 채점: prep.py 의 gold expectation 을 새 출력형식(notifications)에 맞춰 재해석
def _event_date(c: dict) -> date | None:
    return _parse_d(c.get("raw_date")) if c.get("raw_date") else None


def grade_gold(plan: dict, dataset: list[dict]) -> dict:
    by_key = {c["key"]: c for c in dataset}
    report = {}
    for c in dataset:
        if c.get("real_tag") != "gold":
            continue
        g = c.get("gold") or {}
        res = plan.get(c["key"], {})
        notes = res.get("notifications", []) or []
        notes = [n for n in notes if isinstance(n, dict)]
        n_count = len(notes)
        has_repeat = any(n.get("repeat_rule") for n in notes)
        ev = _event_date(c)
        has_D1 = False
        if ev:
            for n in notes:
                d = _parse_d(n.get("date"))
                if d and (ev - d).days == 1:
                    has_D1 = True
                    break
        # 기대 충족 판정
        verdict = "X"
        reasons = []
        exp_kind = g.get("expect_triggers_kind")
        if exp_kind in ("periodic_nudge", "light_periodic"):
            # 마감없는 주기 넛지: repeat_rule 또는 다회 알림이 있어야 OK
            if has_repeat or n_count >= 2:
                verdict = "O"
            elif n_count == 1:
                verdict = "△"
                reasons.append("단발만 — 주기성 약함")
            else:
                reasons.append("알림 0 (손 놓음)")
        elif exp_kind == "single_D1":
            if has_D1 and n_count <= 2:
                verdict = "O"
            elif has_D1:
                verdict = "△"
                reasons.append(f"D-1 있으나 과다({n_count}회)")
            else:
                reasons.append("D-1 없음")
        elif exp_kind == "relative_before_deadline":
            # 오늘 마감 과제: 마감 당일/직전 알림(1~2회) — D-1 필수 아님
            if 1 <= n_count <= 3:
                verdict = "O"
            elif n_count == 0:
                reasons.append("알림 0")
            else:
                verdict = "△"
                reasons.append(f"과다({n_count}회)")
        elif exp_kind == "absolute_multistage":
            # 무거운 시험/대회: 다단(>=3) + D-1 포함
            if n_count >= 3 and has_D1:
                verdict = "O"
            elif n_count >= 2:
                verdict = "△"
                reasons.append(f"다단 약함 n={n_count} D1={has_D1}")
            else:
                reasons.append(f"단발/부족 n={n_count}")
        report[c["key"]] = {
            "title": c["title"],
            "expect": exp_kind,
            "verdict": verdict,
            "n_notifications": n_count,
            "has_repeat": has_repeat,
            "has_D1": has_D1,
            "reasons": reasons,
            "reasoning": (res.get("reasoning") or "")[:100],
        }
    o = sum(1 for v in report.values() if v["verdict"] == "O")
    t = sum(1 for v in report.values() if v["verdict"] == "△")
    x = sum(1 for v in report.values() if v["verdict"] == "X")
    return {"summary": {"O": o, "triangle": t, "X": x}, "per_gold": report}


def initial_quality(plan: dict, ordering: list[dict], n_first: int = 6) -> dict:
    """B 의 전파 위험 평가: 시간순 처음 처리된 item 들의 결정이 합리적인가."""
    first = ordering[:n_first]
    rows = []
    for c in first:
        res = plan.get(c["key"], {})
        notes = [n for n in (res.get("notifications") or []) if isinstance(n, dict)]
        has_repeat = any(n.get("repeat_rule") for n in notes)
        # 합리성 휴리스틱: 마감없으면 주기/다회 권장, 마감있으면 1+ 알림 권장, dead-hour 회피
        dead = sum(1 for n in notes if _parse_t(n.get("time")) in DEAD_HOURS)
        if not c.get("raw_date"):
            ok = has_repeat or len(notes) >= 2
            note = "no-deadline→nudge" if ok else "no-deadline but silent/single"
        else:
            ok = len(notes) >= 1
            note = "dated→has reminder" if ok else "dated but empty"
        rows.append(
            {
                "key": c["key"],
                "title": c["title"][:30],
                "n": len(notes),
                "has_repeat": has_repeat,
                "dead_hour": dead,
                "reasonable": ok and dead == 0,
                "note": note,
            }
        )
    return {"n_first": len(rows), "reasonable_count": sum(r["reasonable"] for r in rows), "rows": rows}


# ── main ────────────────────────────────────────────────────────────
def main() -> None:
    dataset = build_dataset()
    orders = two_orderings(dataset)
    n = len(dataset)
    n_calls = n * 4
    print(f"[비용] LLM 호출 예정: {n}케이스 × 4 run (A·B × chrono·shuffled) = {n_calls}콜")
    print(f"[비용] 모델={MODEL} flash-lite temp=0 thinking=0, JSON 구조화. 입력=짧음, 출력=알림 몇개.\n")

    if os.environ.get("DRY_RUN") == "1":
        print("DRY_RUN=1 → 호출 생략, 콜 수만 보고.")
        # 프롬프트 길이 sanity
        ex = dataset[0]
        print(f"  예시 A 프롬프트 길이: {len(user_prompt_A(ex))}자")
        print(f"  예시 B 프롬프트 길이(빈 맥락): {len(user_prompt_B(ex, [], []))}자")
        return

    if not os.environ.get("GOOGLE_CLOUD_PROJECT"):
        print("ERROR: GOOGLE_CLOUD_PROJECT 미설정. 아래로 실행:")
        print("  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\")
        print("    python ../lab/active/recall-notification-planner/ab_planner.py")
        sys.exit(2)

    cli = client()
    print("run A-chrono ...");   A_chrono = run_A(cli, orders["chrono"])
    print("run A-shuffled ..."); A_shuf = run_A(cli, orders["shuffled"])
    print("run B-chrono ...");   B_chrono = run_B(cli, orders["chrono"])
    print("run B-shuffled ..."); B_shuf = run_B(cli, orders["shuffled"])

    A_nd = nondeterminism(A_chrono, A_shuf)
    B_nd = nondeterminism(B_chrono, B_shuf)
    A_gold = grade_gold(A_chrono, dataset)
    B_gold = grade_gold(B_chrono, dataset)
    A_cap = cap_and_bundling(A_chrono, dataset)
    B_cap = cap_and_bundling(B_chrono, dataset)
    B_init = initial_quality(B_chrono, orders["chrono"])

    payload = {
        "model": MODEL, "location": LOCATION, "temperature": 0.0,
        "now": NOW_DT.isoformat(), "today": TODAY.isoformat(),
        "n_cases": n, "n_calls": n_calls,
        "metrics": {
            "nondeterminism": {"A": A_nd, "B": B_nd},
            "gold7": {"A": A_gold, "B": B_gold},
            "cap_bundling": {"A": A_cap, "B": B_cap},
            "initial_quality_B": B_init,
        },
        "raw_plans": {
            "A_chrono": A_chrono, "A_shuffled": A_shuf,
            "B_chrono": B_chrono, "B_shuffled": B_shuf,
        },
        "dataset_order_chrono": [c["key"] for c in orders["chrono"]],
        "dataset_order_shuffled": [c["key"] for c in orders["shuffled"]],
    }
    RESULTS_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = RESULTS_DIR / f"ab_{ts}.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (RESULTS_DIR / "ab_latest.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # ── 콘솔 비교표 ──
    print("\n" + "=" * 64)
    print("비결정성 (입력순서 chrono vs shuffled — 높을수록 안정적)")
    print(f"{'metric':22} {'A(약+독립)':>12} {'B(강+맥락)':>12}")
    for m in ("exact_match_rate", "dateset_match_rate", "count_match_rate", "mean_date_jaccard"):
        print(f"{m:22} {A_nd[m]:>12} {B_nd[m]:>12}")
    print("\ngold7 부합 (O/△/X)")
    print(f"  A: {A_gold['summary']}")
    print(f"  B: {B_gold['summary']}")
    print("\ncap/묶기 (chrono run 전체)")
    print(f"{'metric':24} {'A':>8} {'B':>8}")
    for m in ("total_notifications", "max_per_day", "days_over_2", "days_over_3",
              "dead_hour_placements", "multi_source_days"):
        print(f"{m:24} {A_cap[m]:>8} {B_cap[m]:>8}")
    print(f"\nB 초기품질(시간순 첫 {B_init['n_first']}건 합리적): "
          f"{B_init['reasonable_count']}/{B_init['n_first']}")
    print(f"\n저장: {out}")


if __name__ == "__main__":
    main()
