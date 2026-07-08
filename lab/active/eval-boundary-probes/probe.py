#!/usr/bin/env python3
"""경계 조항 A/B 프로브 (2026-07-08) — v29 잔여 실패 클래스별 소규모 실험.

변형(각각 v29 body 에 조항 1개만 치환·추가, 프로덕션 파일 불변):
- v29  : baseline (동일 미니셋 재측정, 표본 대조용)
- v29b : '기다려온 결과' 조항을 '자기 몫의 결과(지원·신청·참가)'로 한정 — 티저 확인일정 발명 억제,
         단 이 조항의 존재 이유였던 표 결과발표 recall 회귀 감시 (tbl01~06)
- v29c : money 가드를 '자동 발생이 보일 때만'으로 한정 — tm78(수동 이체) 부작용 회수,
         tm08/tm168 은 여전히 todo 로 갈 것으로 예상(=정책 재논의 신호 확인)
- v29d : payload 에 'date 못 박아도 본인 계획이면 type=schedule 유지, date 비움' 허용 —
         '달 초' 계획 memo 강등 회수, date 회귀 감시(dr06·dr16·dr30)

실행: RUN_EVAL=1 PYTHONPATH=. uv run --env-file .env python ../lab/active/eval-boundary-probes/probe.py
"""
import json, os, sys
from pathlib import Path

sys.path.insert(0, "eval")
from run_golden import build_user_text, run_once, _parse_now  # noqa: E402
from scorer import score_case  # noqa: E402
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT  # noqa: E402
from google import genai  # noqa: E402

GOLDEN = Path("eval/golden")
OUT = Path("../lab/active/eval-boundary-probes/results.json")
RUNS = 3

OUTCOME_OLD = ("also when they're waiting on an outcome that lands then and will want to check it "
               "the moment it does.")
OUTCOME_NEW = ("also when they're waiting on an outcome of their own — one they applied, entered, or "
               "submitted into (an acceptance, a result they have a stake in) — that lands then and "
               "will want to check the moment it does. A release or unveiling of content to the world "
               "at large is nobody's own outcome — do not invent a \"check it\" schedule around it.")
MONEY_OLD = ("- Money that moves on its own is a moment, not a task.")
MONEY_NEW = ("- Money that visibly moves on its own is a moment, not a task. Apply this only when the "
             "capture shows the money moves automatically (billing date, auto-pay, payday, renewal); "
             "a bare instruction to move money yourself (transfer X, pay Y) with no sign of automation "
             "is the user's own act — todo.")
DATELESS_ADD = ("Only a date the capture gives no basis for at all is an invention to withhold.")
DATELESS_NEW = (DATELESS_ADD + " The reverse also holds: when the plan is the user's own but the words "
                "give only a rough window (early next month), keep it a schedule with date empty — "
                "don't demote the plan to memo just because the day can't be pinned.")

def variant(body, old, new):
    assert old in body, f"clause not found: {old[:40]}"
    return body.replace(old, new)

BODY = ACTIVE_PROMPT.body
VARIANTS = {
    "v29": BODY,
    "v29b": variant(BODY, OUTCOME_OLD, OUTCOME_NEW),
    "v29c": variant(BODY, MONEY_OLD, MONEY_NEW),
    "v29d": variant(BODY, DATELESS_ADD, DATELESS_NEW),
}
CASE_IDS = {
    "text_classification_boundary.json": ["tm174", "tm08", "tm168", "tm09", "tm172"],
    "text_classification_clear.json": ["tm78", "tm41", "tm43"],
    "date_resolution.json": ["dr06", "dr16", "dr30"],
    "table_decomposition.json": ["tbl01", "tbl02", "tbl03", "tbl04", "tbl05", "tbl06"],
}
# 변형별 표적(개선 기대) / 나머지는 회귀 감시
TARGET = {"v29b": {"tm174"}, "v29c": {"tm78"}, "v29d": {"tm09", "tm172"}}

def main():
    cases = []
    for fn, ids in CASE_IDS.items():
        doc = {c["id"]: c for c in json.loads((GOLDEN / fn).read_text())["cases"]}
        cases += [doc[i] for i in ids]
    client = genai.Client(vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location="global")
    model = os.environ.get("GEMINI_MODEL", ACTIVE_PROMPT.model_target)
    results = {}
    for vname, body in VARIANTS.items():
        row = {}
        for c in cases:
            now = _parse_now(c["input"].get("pinned_now"))
            ut = build_user_text(c["input"], now)
            passes = 0
            for _ in range(RUNS):
                try:
                    rr = run_once(client, model, body, ut, None)
                    if "output" in rr and score_case(rr["output"], c["expected"])["passed"]:
                        passes += 1
                except Exception:
                    pass
            row[c["id"]] = passes
            print(f"[{vname}] {c['id']} {passes}/{RUNS}", file=sys.stderr)
        results[vname] = row
    OUT.write_text(json.dumps(results, indent=1))
    # 요약표
    ids = [c["id"] for c in cases]
    print("case  " + "  ".join(f"{v:>5}" for v in VARIANTS))
    for i in ids:
        mark = "".join("*" if i in TARGET.get(v, set()) else "" for v in VARIANTS)
        print(f"{i:6}" + "  ".join(f"{results[v][i]:>4}/3" for v in VARIANTS) + f"  {mark}")

if __name__ == "__main__":
    main()
