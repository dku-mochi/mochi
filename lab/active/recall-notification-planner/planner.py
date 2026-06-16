"""알림 플래너 LLM (gemini-3.1-flash-lite, global, temp=0).

질문(부모가 결정): 생성 시점에 LLM 이 item 을 보고 사용자 직관에 맞는 "알림 계획"
(시점들·주기·상대시간)을 짜내는가? 그리고 안정적인가(같은 입력 3회 반복 시 흔들리나)?

입력 = title + intent_type + 날짜정보(있으면) + category + importance + days_until
       + 개인 활동 히스토그램(KST 24h, 죽은시간 명시).
출력(JSON 구조화) = {weight, plan: [{trigger, time_hint, copy_hint}], reasoning}
  trigger 는 "알림 계획 어휘 5종" 으로만 표현하도록 프롬프트로 강제:
    D-n  (절대시각 다단/단발 전날),  마감-Nh / 저장+Nh (상대시간),
    every-Nd-xM (주기 넛지/가벼운 위시 주기).
  time_hint 는 "HH:MM" KST (활동시간대여야 하고 6~10시 회피).

각 케이스 N회(기본 3) 호출해 계획 일관성(안정성)을 본다.

실행 (repo 루트에서, ADC + GOOGLE_CLOUD_PROJECT 필요):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\
    python ../lab/active/recall-notification-planner/planner.py

  콜 수만 보려면:  DRY_RUN=1 python lab/active/recall-notification-planner/planner.py
  반복횟수 조정:   REPEATS=3

결과: results/planner_YYYYMMDD_HHMMSS.json (+ results/planner_latest.json)
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from prep import (  # noqa: E402
    ACTIVITY_DESC,
    ACTIVITY_HISTOGRAM,
    CAPTURE_NOW,
    TODAY,
    all_cases,
    days_until,
)

sys.stdout.reconfigure(encoding="utf-8")

MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"
RESULTS_DIR = Path(__file__).parent / "results"
REPEATS = int(os.environ.get("REPEATS", "3"))

SYSTEM = (
    "너는 모찌(개인 기억 비서)의 '알림 플래너'다. 사용자가 무언가를 저장한 그 순간, "
    "이걸 앞으로 '언제·몇 번·어떤 시각에' 다시 떠올려줄지 계획을 짠다. "
    "모찌의 미션은 '필요한 기억은 알아서 떠오른다' — 사용자가 직접 찾게 두지 않고, "
    "네가 능동적으로 적절한 타이밍에 깨워주는 게 핵심이다.\n\n"
    "## weight (알림 강도)\n"
    "놓쳤을 때 후회의 크기 × 미리 알아야 할 준비량으로 정한다.\n"
    "- heavy: 준비가 길거나(공부·서류) 놓치면 되돌릴 수 없는 일(시험·접수마감). 일찍부터 여러 번.\n"
    "- medium: 약간의 준비/조율이 필요하나 치명적이지 않은 일.\n"
    "- light: 가벼운 약속·다짐·위시. 적게.\n\n"
    "## plan — 알림 시점들. 각 시점의 trigger 는 아래 '어휘 5종' 으로만 표현하라:\n"
    "1) 절대시각 다단/단발: \"D-n\" (마감/일정일 n일 전). 예 무거운 시험=D-14,D-7,D-3,D-1 / 가벼운 약속=D-1 단발.\n"
    "2) 상대시간(마감 기준): \"마감-Nh\" (마감 N시간 전). 마감이 오늘처럼 임박했고 날짜만으론 부족할 때.\n"
    "3) 상대시간(저장 기준): \"저장+Nh\" (저장 시점 N시간 뒤). 곧 처리해야 할 일을 저장 직후 한 번 깨울 때.\n"
    "4) 주기 넛지: \"every-Nd-xM\" (N일마다, 총 M회). **마감/날짜가 없는 지속적 의도**(예: 누구에게 연락, "
    "습관·다짐)에 쓴다. 마감이 없다고 손 놓지 말고 스스로 적절한 주기와 총 횟수를 정하라.\n"
    "5) 가벼운 위시 주기: \"every-Nd-xM\" 이되 더 긴 주기·적은 횟수. 위시리스트/쇼핑 욕구처럼 급하지 않은 것.\n\n"
    "중요: 마감(deadline/date)이 없는 항목이라고 알림을 비우지 마라. 그런 항목이야말로 "
    "주기 넛지(every-Nd-xM)로 사용자가 잊지 않게 능동적으로 떠올려줘야 한다. "
    "단, 위시/쇼핑처럼 가벼운 건 길고 드물게, 연락/다짐처럼 관계·실천이 걸린 건 좀 더 촘촘히.\n\n"
    "## time_hint — 각 알림을 보낼 시각 \"HH:MM\" (KST 24시간).\n"
    f"{ACTIVITY_DESC} 활동 히스토그램(시:상대활동량 0~3)을 사용자 입력에서 받는다. "
    "활동량이 높은 시간대에 배치하고, 활동량 0(특히 오전 6~10시 수면)에는 절대 보내지 마라.\n\n"
    "## copy_hint — 그 알림에 띄울 짧은 문구 한 줄(한국어). 상대시간 마감 직전이면 "
    "'혹시 벌써 제출하셨나요?' 처럼 이미 했을 가능성도 배려.\n\n"
    "reasoning 은 왜 이 weight·이 계획인지 한국어 한두 줄."
)


def _hist_str() -> str:
    # 활동 히스토그램을 컴팩트하게 (시:량)
    return ", ".join(f"{h:02d}:{v}" for h, v in sorted(ACTIVITY_HISTOGRAM.items()))


def user_prompt(c: dict) -> str:
    du = days_until(c.get("raw_date"))
    date_line = (
        f"- 날짜정보: {c['date_key']}={c['raw_date']} (오늘로부터 days_until={du})\n"
        if c.get("raw_date")
        else "- 날짜정보: 없음 (마감/일정일이 지정되지 않은 항목)\n"
    )
    summary_line = f"- summary: {c['summary']}\n" if c.get("summary") else ""
    return (
        f"오늘은 {TODAY.isoformat()}, 사용자가 방금 이 항목을 저장했다 (저장 시각 {CAPTURE_NOW.strftime('%H:%M')} KST).\n"
        f"- title: {c['title']}\n"
        f"- intent_type: {c['intent_type']}\n"
        f"- category: {c.get('category')}\n"
        f"- importance(1~5, 참고용): {c.get('importance')}\n"
        f"{date_line}"
        f"{summary_line}"
        f"- 이 사용자의 활동 히스토그램(KST 시:활동량 0~3): {_hist_str()}\n"
        "이 항목의 알림 weight 와 plan(시점들)을 정하라. "
        "trigger 는 D-n / 마감-Nh / 저장+Nh / every-Nd-xM 중 하나로만 적어라."
    )


# ── 구조화 출력 스키마 ─────────────────────────────────────────────
def schema_dict() -> dict:
    """response_schema (OpenAPI subset). pydantic 대신 dict 로 — every-Nd-xM 같은 자유형 string 강제."""
    return {
        "type": "object",
        "properties": {
            "weight": {"type": "string", "enum": ["heavy", "medium", "light"]},
            "plan": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "trigger": {
                            "type": "string",
                            "description": "D-n | 마감-Nh | 저장+Nh | every-Nd-xM 중 하나",
                        },
                        "time_hint": {"type": "string", "description": "HH:MM KST"},
                        "copy_hint": {"type": "string"},
                    },
                    "required": ["trigger", "time_hint", "copy_hint"],
                },
            },
            "reasoning": {"type": "string"},
        },
        "required": ["weight", "plan", "reasoning"],
    }


def client():
    from google import genai

    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def plan_once(cli, case: dict) -> dict:
    from google.genai import types

    resp = cli.models.generate_content(
        model=MODEL,
        contents=[types.Content(role="user", parts=[types.Part.from_text(text=user_prompt(case))])],
        config=types.GenerateContentConfig(
            system_instruction=SYSTEM,
            response_mime_type="application/json",
            response_schema=schema_dict(),
            temperature=0.0,
        ),
    )
    return json.loads(resp.text)


def main() -> None:
    cases = all_cases()
    n_calls = len(cases) * REPEATS
    print(f"[비용] LLM 호출 예정: {len(cases)}케이스 × {REPEATS}회 = {n_calls}콜 "
          f"(모델={MODEL}, flash-lite, JSON 구조화 출력)")
    print(f"[비용] 입력 토큰 작음(title+필드+히스토그램 1줄), 출력 작음(plan 몇 시점). "
          f"안정성 측정 위해 동일입력 {REPEATS}회 반복.\n")

    if os.environ.get("DRY_RUN") == "1":
        print("DRY_RUN=1 → 호출 생략, 콜 수만 보고.")
        return

    if not os.environ.get("GOOGLE_CLOUD_PROJECT"):
        print("ERROR: GOOGLE_CLOUD_PROJECT 미설정. 아래로 실행:")
        print("  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\")
        print("    python ../lab/active/recall-notification-planner/planner.py")
        sys.exit(2)

    cli = client()
    rows = []
    for case in cases:
        runs = []
        for r in range(REPEATS):
            try:
                runs.append({"run": r, **plan_once(cli, case)})
            except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
                runs.append({"run": r, "error": str(e)[:300]})
        # 콘솔 요약: 각 run 의 weight + trigger 시퀀스
        for run in runs:
            if "error" in run:
                print(f"  {case['key']:30} run{run['run']} ERR {run['error'][:60]}")
            else:
                trigs = "|".join(p["trigger"] for p in run.get("plan", []))
                times = "|".join(p["time_hint"] for p in run.get("plan", []))
                print(f"  {case['key']:30} run{run['run']} {run['weight']:6} [{trigs}] @[{times}]")
        rows.append({"case": case, "runs": runs})

    RESULTS_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = RESULTS_DIR / f"planner_{ts}.json"
    payload = {
        "model": MODEL,
        "location": LOCATION,
        "temperature": 0.0,
        "repeats": REPEATS,
        "today": TODAY.isoformat(),
        "capture_now": CAPTURE_NOW.isoformat(),
        "activity_histogram": ACTIVITY_HISTOGRAM,
        "n_cases": len(cases),
        "n_calls": n_calls,
        "results": rows,
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    latest = RESULTS_DIR / "planner_latest.json"
    latest.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n저장: {out}\n      {latest}")


if __name__ == "__main__":
    main()
