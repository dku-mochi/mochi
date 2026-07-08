#!/usr/bin/env python3
"""'가장 이른 날' 앵커 프로브 — 미기재 이벤트의 저해상도 시기(담주·주말·다음달)에
date=창의 시작일을 채우는지. v29 vs v29e(조항 추가). 회귀 감시: 명시 요일·미정=memo 유지.
실행: RUN_EVAL=1 PYTHONPATH=. uv run --env-file .env python ../lab/active/eval-boundary-probes/probe2.py
"""
import json, os, sys
sys.path.insert(0, "eval")
from run_golden import build_user_text, run_once, _parse_now
from scorer import score_case
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT
from google import genai

NOW = "2026-06-19T15:38:00+09:00"
ANCHOR = ("Only a date the capture gives no basis for at all is an invention to withhold.")
ANCHOR_NEW = (ANCHOR + " And when the user's own event is real but the words give only a window — "
              "next week, this weekend, next month — anchor date at the earliest day that window "
              "can mean (next week → its Monday, this weekend → its Saturday, next month → the "
              "1st): an early reminder lets the user confirm the exact day, while a late one "
              "arrives after the moment and defeats the reminder. The title keeps the user's "
              "rough wording so they can correct it. This applies only to events that exist with "
              "an unstated day — a plan whose day is not yet decided at all is still a memo.")
BODY = ACTIVE_PROMPT.body
assert ANCHOR in BODY
VARIANTS = {"v29": BODY, "v29e": BODY.replace(ANCHOR, ANCHOR_NEW)}
C = lambda i, t, exp: {"id": i, "input": {"text": t, "pinned_now": NOW}, "expected": exp}
CASES = [
    C("p1", "엄마 생신 담주", {"core": [{"name": "생신", "kw": ["생신"], "type": "schedule", "date": "2026-06-22"}]}),
    C("p2", "담주 팀 워크숍", {"core": [{"name": "워크숍", "kw": ["워크숍"], "type": "schedule", "date": "2026-06-22"}]}),
    C("p3", "이번 주말 부모님 저녁", {"core": [{"name": "저녁", "kw": ["부모님"], "type": "schedule", "date": "2026-06-20"}]}),
    C("p4", "다다음주 출장", {"core": [{"name": "출장", "kw": ["출장"], "type": "schedule", "date": "2026-06-29"}]}),
    C("p5", "다음 달 가족 여행", {"core": [{"name": "여행", "kw": ["여행"], "type": "schedule", "date": "2026-07-01"}]}),
    C("r1", "담주 화요일 오후 3시 디자인 미팅", {"core": [{"name": "미팅", "kw": ["미팅"], "type": "schedule", "date": "2026-06-23"}]}),
    C("r2", "이번 주말 토요일 브런치", {"core": [{"name": "브런치", "kw": ["브런치"], "type": "schedule", "date": "2026-06-20"}]}),
    C("r3", "담달 초 제주", {"intent_set": ["memo"], "count_band": {"min": 1, "max": 1}}),
    C("r4", "8월 초 부모님 제주 모시고 가기", {"intent_set": ["memo"], "count_band": {"min": 1, "max": 1}}),
]
client = genai.Client(vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location="global")
model = os.environ.get("GEMINI_MODEL", ACTIVE_PROMPT.model_target)
res = {}
for v, body in VARIANTS.items():
    for c in CASES:
        ut = build_user_text(c["input"], _parse_now(NOW))
        n = 0
        dates = []
        for _ in range(3):
            try:
                rr = run_once(client, model, body, ut, None)
                sc = score_case(rr["output"], c["expected"])
                if sc["passed"]: n += 1
                dc = sc.get("date_check")
                if dc: dates.append(list(dc.values())[0][0])
            except Exception: pass
        res.setdefault(c["id"], {})[v] = (n, dates)
for cid, d in res.items():
    print(f"{cid}: v29={d['v29'][0]}/3 {d['v29'][1]}  v29e={d['v29e'][0]}/3 {d['v29e'][1]}")
