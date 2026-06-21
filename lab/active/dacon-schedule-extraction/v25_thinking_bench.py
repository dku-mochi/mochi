#!/usr/bin/env python3
"""v25 thinking_budget A/B — auto(-1, dynamic) 가 결과발표 recall 천장(~75%)을 깨나.

선행: v23_ab_bench.py / v24b_config_bench.py / v25_ab_bench.py (셋업·8축 채점·회귀 재사용)
==============================================================================
배경
------------------------------------------------------------------------------
production 이 방금 v25(classify_and_act@v25)로 반영됐다. v25 는 thinking_budget=0 에서
결과발표(schedule 07-27) schedule-골든이 ~6/8(75%) 천장이었다 — 누락은 과생성이 아닌
"안전한 누락"(flash-lite 변동성). 사용자는 thinking_budget=auto(-1, dynamic)로 v25 를
10회 돌려 결과발표 recall 이 그 위로 올라가는지, 어떤 부작용·비용이 따르는지 본다.

-1=dynamic 은 v24b 에서 SDK live probe 로 확인됨(재조사 불필요).

프로덕션 충실 재현 (drift 0)
------------------------------------------------------------------------------
- prompt body = production ``ACTIVE_PROMPT.body`` **그대로** import (= v25). 재조립 금지.
  시작 시 ACTIVE_PROMPT.name == 'classify_and_act@v25' 를 assert. 아니면 멈추고 보고.
- function schema(_FINALIZE/_FINALIZE_PARAMS) / 시간컨텍스트(2026-06-19 15:38 KST,
  _korea_time_context) / temperature 0.3 / Vertex AI(global) / tool mode=ANY /
  이미지 inline / finalizeAnalysis 1-shot — 전부 production·선행과 동일.
- **arm 간 유일한 차이 = thinking_budget. max_output_tokens 는 둘 다 4096.**
  (thinking 켜면 thoughts 가 출력예산을 먹는다 — v24b_think 가 1024 에서 finalize 전멸한 교훈.
   공정 비교를 위해 baseline(thinking0)도 4096 로 통일. 즉 token 변수를 제거하고 thinking 만 격리.)

ARMS (dacon 이미지, 각 10회)
------------------------------------------------------------------------------
  v25_think0    thinking_budget=0   max_output_tokens=4096  ← baseline (이번 세션 재측정)
  v25_thinkauto thinking_budget=-1  max_output_tokens=4096  ← 주 arm (dynamic thinking)

각 run: thoughts 토큰 · latency · finish_reason 기록(thinking 비용/절단 관측).

회귀 (필수)
------------------------------------------------------------------------------
thinking auto 가 단순 캡처를 망치는지 — v24b 에서 thinking 은 단일 의도 캡처를 memo+needs_review
로 후퇴시키고 화면 노이즈("데이스쿨 할인")를 흡수한 전력이 있다. 단순 캡처 3장(화장품·공차·
기프티콘) thinking0 vs thinkauto 각 3회 instance 수 + needs_review + 노이즈 흡수 여부.

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/v25_thinking_bench.py
"""

import json
import mimetypes
import os
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from google import genai
from google.genai import types

# mochi-backend 를 sys.path 에 넣어 cwd 와 무관하게 production `app` 패키지를 import.
_BACKEND = Path(__file__).resolve().parents[3] / "mochi-backend"
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

# --- production 모듈 직접 import (read-only) — prompt/schema/time-ctx drift 0 ---
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE, _FINALIZE_PARAMS  # noqa: E402
from app.modules.agent.application.orchestrator import _korea_time_context  # noqa: E402

# --- 선행 실험에서 8축 채점 + 회귀이미지 재사용 (재구현 금지) ---
sys.path.insert(0, str(Path(__file__).parent))
from v23_ab_bench import (  # noqa: E402
    score_dacon,
    aggregate,
    CORE,
    REGRESSION_DIR,
    REGRESSION_IMAGES,
    N_REGRESSION_RUNS,
)

DACON_IMAGE = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 10

# 재현성: 2026-06-19 (금) 15:38 KST 고정 (선행과 동일).
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))
AGENT_LOCATION = "global"

# arm 정의: (label, file_prefix, thinking_budget, max_output_tokens)
ARMS = [
    ("v25_think0", "v25_think0", 0, 4096),       # baseline
    ("v25_thinkauto", "v25_thinkauto", -1, 4096),  # 주 arm — dynamic thinking
]

# 결과발표 골든 보강 체크 (score_dacon 의 recall 매칭과 별개로, schedule·날짜·시간 정밀 일치).
GOLDEN_RESULT = {"type": "schedule", "date": "2026-07-27", "time": "14:00"}


def _load_env() -> None:
    env_path = Path(__file__).resolve().parents[3] / "mochi-backend" / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if k in ("GOOGLE_CLOUD_PROJECT", "GEMINI_MODEL") and k not in os.environ:
            os.environ[k] = v


def _build_user_message() -> str:
    blocks = [
        _korea_time_context(PINNED_NOW),
        "첨부된 스크린샷/이미지를 함께 분석하세요.",
    ]
    return "\n\n".join(blocks)


def _image_part(path: Path) -> types.Part:
    mime = mimetypes.guess_type(str(path))[0] or "image/png"
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)


def _finalize_declaration() -> types.FunctionDeclaration:
    return types.FunctionDeclaration(
        name=_FINALIZE,
        description="Emit the final structured analysis. Call exactly once when ready.",
        parameters=_FINALIZE_PARAMS,
    )


def _extract_finalize_args(resp) -> dict | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None) == _FINALIZE:
                return dict(fc.args or {})
    return None


def _usage(resp) -> dict:
    um = getattr(resp, "usage_metadata", None)
    if um is None:
        return {}
    return {
        "thoughts_tokens": getattr(um, "thoughts_token_count", None),
        "candidates_tokens": getattr(um, "candidates_token_count", None),
        "total_tokens": getattr(um, "total_token_count", None),
    }


def _result_golden_match(output: dict) -> dict:
    """결과발표 골든(schedule·07-27·14:00) 정밀 일치 — recall 키워드 매칭과 별개 보강."""
    kws = CORE["결과발표"]["kw"]
    for ins in output.get("intent_instances", []) or []:
        p = ins.get("payload", {})
        txt = " ".join(str(x) for x in [p.get("title", ""), ins.get("label", ""),
                                        ins.get("reasoning", ""), p.get("note", "")])
        if any(k in txt for k in kws):
            got = {
                "type": ins.get("intent_type"),
                "date": (p.get("date") or p.get("deadline") or "")[:10] or None,
                "time": p.get("time"),
                "title": p.get("title"),
            }
            return {
                "found": True,
                "got": got,
                "type_ok": got["type"] == GOLDEN_RESULT["type"],
                "date_ok": got["date"] == GOLDEN_RESULT["date"],
                "time_ok": got["time"] == GOLDEN_RESULT["time"],
                "full_golden": (got["type"] == GOLDEN_RESULT["type"]
                                and got["date"] == GOLDEN_RESULT["date"]
                                and got["time"] == GOLDEN_RESULT["time"]),
            }
    return {"found": False, "got": None, "type_ok": False, "date_ok": False,
            "time_ok": False, "full_golden": False}


def run_once(client, model, system_prompt, image, thinking_budget, max_tokens) -> dict:
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=max_tokens,
        thinking_config=types.ThinkingConfig(thinking_budget=thinking_budget),
        tools=[types.Tool(function_declarations=[_finalize_declaration()])],
        tool_config=types.ToolConfig(
            function_calling_config=types.FunctionCallingConfig(mode="ANY")
        ),
    )
    contents = [
        types.Content(role="user", parts=[types.Part(text=_build_user_message()), _image_part(image)])
    ]
    t0 = time.perf_counter()
    resp = client.models.generate_content(model=model, contents=contents, config=cfg)
    latency_ms = round((time.perf_counter() - t0) * 1000, 1)
    args = _extract_finalize_args(resp)
    out = {"latency_ms": latency_ms, "usage": _usage(resp)}
    cands = getattr(resp, "candidates", None) or []
    out["finish_reason"] = str(getattr(cands[0], "finish_reason", None)) if cands else None
    if args is None:
        out["error"] = "no finalizeAnalysis call"
        out["raw_text"] = getattr(resp, "text", None)
    else:
        out["output"] = args
    return out


def run_arm(client, model, body, label, file_prefix, thinking_budget, max_tokens) -> list[dict]:
    runs = []
    print(f"\n=== ARM {label}  (thinking_budget={thinking_budget}, max_tokens={max_tokens}) ===",
          file=sys.stderr)
    for i in range(1, N_RUNS + 1):
        try:
            r = run_once(client, model, body, DACON_IMAGE, thinking_budget, max_tokens)
        except Exception as e:  # noqa: BLE001
            r = {"error": f"{type(e).__name__}: {e}"}
        r["run"] = i
        r["arm"] = label
        r["config"] = {"thinking_budget": thinking_budget, "max_output_tokens": max_tokens}
        (RESULTS_DIR / f"{file_prefix}_run_{i}.json").write_text(
            json.dumps(r, ensure_ascii=False, indent=2)
        )
        if "output" in r:
            sc = score_dacon(r["output"])
            gm = _result_golden_match(r["output"])
            r["score"] = sc
            r["result_golden"] = gm
            u = r.get("usage", {})
            print(f"[{label} run {i}] {r.get('latency_ms')}ms  finish={r.get('finish_reason')}  "
                  f"thoughts={u.get('thoughts_tokens')}  cand={u.get('candidates_tokens')}  "
                  f"n={sc['n']}  recall={sc['recall']}/3  "
                  f"결과발표={sc['recall_detail'].get('결과발표')}(golden={gm['full_golden']})  "
                  f"over={sc['over']}  span={sc['span_misuse']}  date_ok={sc['date_accuracy']}  "
                  f"type_ok={sc['type_ok']}  noise={sc['noise']}  nr={sc['needs_review']}",
                  file=sys.stderr)
            for ins in r["output"].get("intent_instances", []):
                p = ins.get("payload", {})
                d = p.get("date") or p.get("deadline") or "-"
                if p.get("time"):
                    d = f"{d} {p['time']}"
                if p.get("end_date"):
                    d = f"{d} ~ {p['end_date']}"
                print(f"     - {str(ins.get('intent_type')):8s} | "
                      f"{str(p.get('title', '?'))[:34]:34s} | {d}", file=sys.stderr)
        else:
            print(f"[{label} run {i}] ERROR/finish={r.get('finish_reason')}: {r.get('error')}",
                  file=sys.stderr)
        runs.append(r)
    return runs


def run_regression(client, model, body) -> list[dict]:
    """단순 캡처 회귀: thinking0 vs thinkauto 각 N_REGRESSION_RUNS 회.

    같은 v25 body, arm 차이는 thinking_budget 만. needs_review·노이즈 흡수도 같이 본다.
    """
    print("\n=== REGRESSION (단순 캡처: thinking0 vs thinkauto) ===", file=sys.stderr)
    noise_kw = ["dacon.io", "데이스쿨", "할인", "리턴즈", "참가신청 대기", "D-11", "58%", "커뮤니티", "더보기"]
    rows = []
    for fname, desc in REGRESSION_IMAGES:
        img = REGRESSION_DIR / fname
        entry = {"image": fname, "desc": desc}
        if not img.exists():
            entry["error"] = "image not found"
            rows.append(entry)
            print(f"  [SKIP] {fname} not found", file=sys.stderr)
            continue
        for key, tb in (("think0", 0), ("thinkauto", -1)):
            counts, nrs, noises, detail = [], [], [], []
            for _ in range(N_REGRESSION_RUNS):
                try:
                    r = run_once(client, model, body, img, tb, 4096)
                except Exception as e:  # noqa: BLE001
                    r = {"error": f"{type(e).__name__}: {e}"}
                if "output" in r:
                    insts = r["output"].get("intent_instances", []) or []
                    def _txt(ins):
                        p = ins.get("payload", {})
                        return " ".join(str(x) for x in [p.get("title", ""), ins.get("label", ""),
                                                         ins.get("reasoning", ""), p.get("note", "")])
                    noise_hit = any(any(k in _txt(ins) for k in noise_kw) for ins in insts)
                    counts.append(len(insts))
                    nrs.append(r["output"].get("needs_review"))
                    noises.append(noise_hit)
                    detail.append({
                        "n": len(insts),
                        "types": [x.get("intent_type") for x in insts],
                        "titles": [x.get("payload", {}).get("title") for x in insts],
                        "needs_review": r["output"].get("needs_review"),
                        "noise": noise_hit,
                    })
                else:
                    counts.append(None)
                    nrs.append(None)
                    noises.append(None)
                    detail.append({"error": r.get("error")})
            valid = [c for c in counts if c is not None]
            entry[f"{key}_counts"] = counts
            entry[f"{key}_avg"] = round(sum(valid) / len(valid), 2) if valid else None
            entry[f"{key}_needs_review"] = nrs
            entry[f"{key}_noise"] = noises
            entry[f"{key}_runs"] = detail
        print(f"  {desc[:24]:24s}  think0 n={entry['think0_counts']}(avg {entry['think0_avg']}) "
              f"nr={entry['think0_needs_review']} noise={entry['think0_noise']}  ||  "
              f"thinkauto n={entry['thinkauto_counts']}(avg {entry['thinkauto_avg']}) "
              f"nr={entry['thinkauto_needs_review']} noise={entry['thinkauto_noise']}", file=sys.stderr)
        rows.append(entry)
    return rows


def _mean(runs, key, sub=None):
    vals = []
    for r in runs:
        v = r.get(key) if sub is None else (r.get(key) or {}).get(sub)
        if isinstance(v, (int, float)):
            vals.append(v)
    return round(sum(vals) / len(vals), 1) if vals else None


def _enrich_agg(agg_block, runs):
    agg_block["latency_ms_mean"] = _mean(runs, "latency_ms")
    agg_block["thoughts_tokens_mean"] = _mean(runs, "usage", "thoughts_tokens")
    agg_block["candidates_tokens_mean"] = _mean(runs, "usage", "candidates_tokens")
    agg_block["finish_reasons"] = dict(Counter(str(r.get("finish_reason")) for r in runs))
    # 결과발표 schedule-골든 (/N): score_dacon recall_detail 의 결과발표 True 횟수
    scored = [r for r in runs if "score" in r]
    rg = [r["result_golden"] for r in runs if "result_golden" in r]
    agg_block["result_schedule_caught"] = (
        f"{sum(1 for r in scored if r['score']['recall_detail'].get('결과발표'))}/{len(scored)}"
        if scored else None
    )
    agg_block["result_full_golden"] = (
        f"{sum(1 for g in rg if g['full_golden'])}/{len(rg)}" if rg else None
    )
    agg_block["result_type_ok"] = (
        f"{sum(1 for g in rg if g['type_ok'])}/{len(rg)}" if rg else None
    )
    agg_block["result_date_ok"] = (
        f"{sum(1 for g in rg if g['date_ok'])}/{len(rg)}" if rg else None
    )
    agg_block["result_time_ok"] = (
        f"{sum(1 for g in rg if g['time_ok'])}/{len(rg)}" if rg else None
    )
    return agg_block


def main() -> int:
    _load_env()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    model = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite")
    if not project:
        print("BLOCKER: GOOGLE_CLOUD_PROJECT not found", file=sys.stderr)
        return 2
    if not DACON_IMAGE.exists():
        print(f"BLOCKER: dacon image not found: {DACON_IMAGE}", file=sys.stderr)
        return 2

    # production 이 v25 로 반영됐는지 확인 — 아니면 멈추고 보고 (재조립 안 함).
    if ACTIVE_PROMPT.name != "classify_and_act@v25":
        print(f"BLOCKER: ACTIVE_PROMPT.name={ACTIVE_PROMPT.name!r} != 'classify_and_act@v25'. "
              f"production 이 v25 로 반영되지 않았다. 멈춤.", file=sys.stderr)
        return 2

    v25_body = ACTIVE_PROMPT.body  # production 그대로 (재조립 금지)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"model={model}  base={ACTIVE_PROMPT.name}  transport=vertex/{AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"prompt = production ACTIVE_PROMPT.body (v25), len={len(v25_body)} — FIXED across all arms",
          file=sys.stderr)
    print(f"ASSERT OK: ACTIVE_PROMPT.name == 'classify_and_act@v25'", file=sys.stderr)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)

    all_runs = {}
    for label, prefix, tb, mt in ARMS:
        all_runs[label] = run_arm(client, model, v25_body, label, prefix, tb, mt)

    regression = run_regression(client, model, v25_body)

    agg = {}
    for label, runs in all_runs.items():
        agg[label] = _enrich_agg(aggregate(runs), runs)

    print("\n=== AGGREGATE (think0 vs thinkauto) ===", file=sys.stderr)
    print(json.dumps(agg, ensure_ascii=False, indent=2), file=sys.stderr)

    summary = {
        "meta": {
            "experiment": "v25 thinking_budget A/B — thinking0 vs thinkauto(-1 dynamic). "
                          "결과발표 recall 천장(~75%)을 깨나 + 부작용/비용.",
            "model": model,
            "base_prompt": ACTIVE_PROMPT.name,
            "prompt": "production ACTIVE_PROMPT.body (v25), imported as-is (no rebuild)",
            "prompt_len": len(v25_body),
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs_per_arm": N_RUNS,
            "n_regression_runs": N_REGRESSION_RUNS,
            "dacon_image": str(DACON_IMAGE),
            "client": f"vertex(project,location={AGENT_LOCATION})_inline_base64",
            "arms": {label: {"thinking_budget": tb, "max_output_tokens": mt}
                     for label, _, tb, mt in ARMS},
            "result_golden": GOLDEN_RESULT,
            "core_targets": {k: {kk: vv for kk, vv in v.items() if kk != "kw"} for k, v in CORE.items()},
        },
        "aggregate": agg,
        "dacon": all_runs,
        "regression": regression,
    }
    (RESULTS_DIR / "v25_thinking_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2)
    )
    print(f"\n→ {RESULTS_DIR}/v25_thinking_summary.json + "
          f"v25_think0_run_*.json + v25_thinkauto_run_*.json", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
