#!/usr/bin/env python3
"""v24b — 프롬프트는 v23 고정, 호출 config(thinking_budget·max_output_tokens)만 상향.

선행: v23_ab_bench.py (재사용)
------------------------------------------------------------------------------
v23 측정에서 두 결함이 남았다:
  (1) 결과발표(schedule 07-27) 0/5 미회복.
  (2) 우산 span 오용 5/5 ("대회 참가 기간" 07.01~07.15 를 schedule 화).
lab 진단은 max_output_tokens=1024 + thinking_budget=0 (추론 off / 출력 절단) 을
원인 후보로 봤다. 본 실험은 **프롬프트를 v23 그대로 두고 config 만 상향**해서
config 로 두 결함이 풀리는지를 검증한다. v24a(프롬프트 재개선)는 overfit 폐기 — 안 만든다.

프로덕션 충실 재현 (drift 0)
------------------------------------------------------------------------------
- v23 body = production ``ACTIVE_PROMPT.body``(=v22) 에 선행 _V23_BLOCK 1개를
  surgical 삽입(v23_ab_bench 의 _build_v23_body 재사용). 모든 arm 이 같은 v23 body.
- function schema(_FINALIZE/_FINALIZE_PARAMS) / 시간컨텍스트(2026-06-19 15:38 KST,
  _korea_time_context) / temperature 0.3 / Vertex AI(global) / tool mode=ANY /
  이미지 inline / finalizeAnalysis 1-shot — 전부 production·선행과 동일.
- **arm 간 유일한 차이 = thinking_budget 과 max_output_tokens 두 개.**

thinking_budget 범위 확인 (live probe, SDK genai 2.6.0, gemini-3.1-flash-lite/Vertex)
------------------------------------------------------------------------------
  budget=0           → thoughts_tokens=None (추론 off, 현 production)
  budget=-1 (dynamic)→ thoughts_tokens≈121 (auto, 모델이 추론량 결정)  ← v24b 채택
  budget=2048        → thoughts_tokens≈42  (고정 상한)
  thinking_level LOW/HIGH 도 동작하나 task 의 주 변수는 thinking_budget 이라 그것으로 통일.
→ 블로커 없음. dynamic(-1) 을 주 arm 으로, 고정 2048 도 isolate 비교에 포함.

ARMS (각 5회, 같은 v23 body·같은 dacon 이미지)
------------------------------------------------------------------------------
  v23_base   thinking_budget=0   max_output_tokens=1024  ← baseline (이번 세션 재측정)
  v24b       thinking_budget=-1  max_output_tokens=4096  ← 주 arm (둘 다 상향)
  v24b_tok   thinking_budget=0   max_output_tokens=4096  ← isolate: token 만
  v24b_think thinking_budget=-1  max_output_tokens=1024  ← isolate: thinking 만
  v24b_fix   thinking_budget=2048 max_output_tokens=4096 ← 고정 budget 대조(보조)

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/v24b_config_bench.py
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
# (app 은 설치 패키지가 아니라 cwd 의존이라, 백그라운드 실행 시 cwd reset 으로 실패할 수 있다.)
_BACKEND = Path(__file__).resolve().parents[3] / "mochi-backend"
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

# --- production 모듈 직접 import (read-only) — prompt/schema/time-ctx drift 0 ---
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT  # noqa: E402
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE, _FINALIZE_PARAMS
from app.modules.agent.application.orchestrator import _korea_time_context

# --- 선행 실험에서 v23 body 빌드 + 8축 채점 재사용 (재구현 금지) ---
sys.path.insert(0, str(Path(__file__).parent))
from v23_ab_bench import (  # noqa: E402
    _build_v23_body,
    score_dacon,
    aggregate,
    CORE,
)


DACON_IMAGE = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 5

# 재현성: 2026-06-19 (금) 15:38 KST 고정 (선행과 동일).
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))
AGENT_LOCATION = "global"

# arm 정의: (label, thinking_budget, max_output_tokens)
ARMS = [
    ("v23_base", 0, 1024),     # baseline (이번 세션 재측정)
    ("v24b", -1, 4096),        # 주 arm — thinking dynamic + token 넉넉
    ("v24b_tok", 0, 4096),     # isolate: token 만 상향
    ("v24b_think", -1, 1024),  # isolate: thinking 만 상향
    ("v24b_fix", 2048, 4096),  # 고정 budget 대조
]


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
    # finish_reason 노출 — MAX_TOKENS 절단이 실제로 일어났는지 직접 확인.
    cands = getattr(resp, "candidates", None) or []
    out["finish_reason"] = str(getattr(cands[0], "finish_reason", None)) if cands else None
    if args is None:
        out["error"] = "no finalizeAnalysis call"
        out["raw_text"] = getattr(resp, "text", None)
    else:
        out["output"] = args
    return out


def run_arm(client, model, body, label, thinking_budget, max_tokens) -> list[dict]:
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
        (RESULTS_DIR / f"{label}_run_{i}.json").write_text(
            json.dumps(r, ensure_ascii=False, indent=2)
        )
        if "output" in r:
            sc = score_dacon(r["output"])
            r["score"] = sc
            u = r.get("usage", {})
            print(f"[{label} run {i}] {r.get('latency_ms')}ms  finish={r.get('finish_reason')}  "
                  f"thoughts={u.get('thoughts_tokens')}  n={sc['n']}  recall={sc['recall']}/3 "
                  f"결과발표={sc['recall_detail'].get('결과발표')}  over={sc['over']}  "
                  f"span={sc['span_misuse']}  date_ok={sc['date_accuracy']}  "
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

    v22_body = ACTIVE_PROMPT.body
    v23_body = _build_v23_body(v22_body)  # surgical-verified inside

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"model={model}  base={ACTIVE_PROMPT.name}  transport=vertex/{AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"prompt = v23 (v22 body + inserted block), len={len(v23_body)} — FIXED across all arms",
          file=sys.stderr)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)

    all_runs = {}
    for label, tb, mt in ARMS:
        all_runs[label] = run_arm(client, model, v23_body, label, tb, mt)

    agg = {label: aggregate(runs) for label, runs in all_runs.items()}

    # latency / thoughts 평균 추가
    def _mean(runs, key, sub=None):
        vals = []
        for r in runs:
            v = r.get(key) if sub is None else (r.get(key) or {}).get(sub)
            if isinstance(v, (int, float)):
                vals.append(v)
        return round(sum(vals) / len(vals), 1) if vals else None

    for label, runs in all_runs.items():
        agg[label]["latency_ms_mean"] = _mean(runs, "latency_ms")
        agg[label]["thoughts_tokens_mean"] = _mean(runs, "usage", "thoughts_tokens")
        agg[label]["finish_reasons"] = dict(
            Counter(str(r.get("finish_reason")) for r in runs)
        )

    print("\n=== AGGREGATE ===", file=sys.stderr)
    print(json.dumps(agg, ensure_ascii=False, indent=2), file=sys.stderr)

    summary = {
        "meta": {
            "experiment": "v24b — prompt v23 FIXED, config (thinking_budget + max_output_tokens) only",
            "model": model,
            "base_prompt": ACTIVE_PROMPT.name,
            "prompt": "v23 = v22 body + single inserted block (surgical-verified)",
            "v23_len": len(v23_body),
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs_per_arm": N_RUNS,
            "dacon_image": str(DACON_IMAGE),
            "client": f"vertex(project,location={AGENT_LOCATION})_inline_base64",
            "arms": {label: {"thinking_budget": tb, "max_output_tokens": mt} for label, tb, mt in ARMS},
            "core_targets": {k: {kk: vv for kk, vv in v.items() if kk != "kw"} for k, v in CORE.items()},
        },
        "aggregate": agg,
        "runs": all_runs,
    }
    (RESULTS_DIR / "v24b_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULTS_DIR}/v24b_summary.json + <arm>_run_*.json", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
