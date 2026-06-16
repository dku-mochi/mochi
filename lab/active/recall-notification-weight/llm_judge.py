"""LLM 무게 판정 (gemini-3.1-flash-lite) — 의미판단이 importance 를 넘어서는 추가가치를 주나.

입력: title + intent_type + importance + days_until (규칙 baseline 과 동일 신호 + title 의미)
출력(JSON): {weight: heavy|medium|light, lead_schedule: ["D-7","D-1",...], reasoning: "..."}

규칙과 같은 신호를 주되, LLM 에게는 title 의 *의미*(이게 토익인지 과제 마감인지 친구 약속인지)
를 추가로 본다. 이 의미가 무게를 importance 와 다르게 가르면 → LLM 의 추가가치.

프롬프트 철학(global CLAUDE §prompt-criteria-over-examples): 좁은 예시 나열 말고 기준+why.
  무게 = "며칠 전부터 여러 번 인지시켜야 후회가 없는가". 준비/돌이킬 수 없음/기회상실이 클수록 heavy.

실행 (repo 루트에서, ADC + GOOGLE_CLOUD_PROJECT 필요):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\
    python ../lab/active/recall-notification-weight/llm_judge.py

결과: results/llm_judge_YYYYMMDD_HHMMSS.json  (+ results/llm_judge_latest.json 심볼릭 대용 복사)
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path

from google import genai
from google.genai import types
from pydantic import BaseModel, Field

sys.path.insert(0, str(Path(__file__).parent))
from prep import TODAY, load_cases  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

MODEL = "gemini-3.1-flash-lite"
LOCATION = "global"
RESULTS_DIR = Path(__file__).parent / "results"

SYSTEM = (
    "너는 모찌(개인 기억 비서)의 알림 무게 판정기다. 사용자의 일정/마감 하나를 보고, "
    "이걸 '며칠 전부터 몇 번 미리 알려야 사용자가 후회하지 않는가'를 정한다.\n\n"
    "판정 기준 — 무게는 '놓쳤을 때 후회의 크기 × 미리 알아야 할 준비량'이다:\n"
    "- heavy: 준비가 길거나(공부·서류·이동), 놓치면 되돌릴 수 없거나(시험·접수마감·비행기), "
    "기회 상실이 큰 일. 며칠~몇 주 전부터 여러 번 인지시켜야 한다.\n"
    "- medium: 약간의 준비나 사전 조율이 필요하지만 치명적이지 않은 일. 2~3일 전 정도면 충분.\n"
    "- light: 당일/하루 전 한 번 알려주면 충분한 가벼운 일(간단한 약속·짧은 처리).\n\n"
    "중요한 점: 주어진 importance(1~5)는 참고 신호일 뿐 *절대 기준이 아니다*. "
    "title 의 실제 의미로 판단하라 — 똑같이 importance 가 높아도 '과제 23:59 제출'은 당일 한 번이면 "
    "충분할 수 있고, '토익 시험'·'대회 기획서'는 며칠 전부터 준비를 깨워야 한다. "
    "반대로 importance 가 낮아 보여도 멀리 있는 큰 일(여행 등 예약·준비가 필요한)은 일찍 알려야 한다.\n\n"
    "lead_schedule 은 무게에 맞는 'D-n' 리스트로(예: heavy=[D-14,D-7,D-3,D-1], medium=[D-3,D-1], "
    "light=[D-1]) — 단 일정의 성격에 맞게 조정 가능. days_until 보다 큰 D-n 은 넣어도 된다(전체 의도 표현). "
    "reasoning 은 왜 그 무게인지 한국어 한 줄."
)


class WeightDecision(BaseModel):
    weight: str = Field(pattern="^(heavy|medium|light)$")
    lead_schedule: list[str]
    reasoning: str


def client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def user_prompt(c: dict) -> str:
    return (
        f"오늘은 {TODAY.isoformat()} 이다.\n"
        f"- title: {c['title']}\n"
        f"- intent_type: {c['intent_type']}\n"
        f"- importance(기존 신호, 참고용): {c['importance']}\n"
        f"- 마감/일정일: {c['due_date']} (days_until={c['days_until']})\n"
        "이 일정의 알림 무게와 lead_schedule 을 정하라."
    )


def decide(c: genai.Client, case: dict) -> WeightDecision:
    resp = c.models.generate_content(
        model=MODEL,
        contents=[types.Content(role="user", parts=[types.Part.from_text(text=user_prompt(case))])],
        config=types.GenerateContentConfig(
            system_instruction=SYSTEM,
            response_mime_type="application/json",
            response_schema=WeightDecision,
            temperature=0.0,
        ),
    )
    return WeightDecision.model_validate_json(resp.text)


def main() -> None:
    cases = load_cases()
    # 콜 수 사전 로그 (부모 지시: 실행 전 콜 수 찍기)
    print(f"[비용] LLM 호출 예정: {len(cases)}콜 (모델={MODEL}, flash-lite, JSON 구조화 출력)")
    print(f"[비용] 입력 토큰 작음(title+4필드), 출력 작음(weight+schedule+reasoning). 26콜 수준.\n")

    if os.environ.get("DRY_RUN") == "1":
        print("DRY_RUN=1 → 호출 생략, 콜 수만 보고.")
        return

    if not os.environ.get("GOOGLE_CLOUD_PROJECT"):
        print("ERROR: GOOGLE_CLOUD_PROJECT 미설정. 아래로 실행:")
        print("  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run --directory mochi-backend \\")
        print("    python ../lab/active/recall-notification-weight/llm_judge.py")
        sys.exit(2)

    cli = client()
    rows = []
    for i, case in enumerate(cases, 1):
        try:
            d = decide(cli, case)
            entry = {**case, "llm_weight": d.weight, "llm_schedule": d.lead_schedule, "llm_reasoning": d.reasoning}
        except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
            entry = {**case, "llm_error": str(e)[:300]}
        rows.append(entry)
        tag = entry.get("llm_weight", "ERR")
        print(f"  [{i:2}/{len(cases)}] imp={case['importance']} d={case['days_until']:>3} "
              f"→ {tag:6} {case['title'][:38]}")

    RESULTS_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = RESULTS_DIR / f"llm_judge_{ts}.json"
    out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    latest = RESULTS_DIR / "llm_judge_latest.json"
    latest.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    from collections import Counter

    wc = Counter(r.get("llm_weight", "ERR") for r in rows)
    print(f"\nLLM 무게 분포: {dict(wc)}")
    print(f"저장: {out}\n      {latest}")


if __name__ == "__main__":
    main()
