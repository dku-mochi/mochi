#!/usr/bin/env python3
"""v25 vs v26 A/B — 분해블록 첫 문단의 분해 트리거 확장(D) + 완전 스캔 지시(E).

선행: v25_ab_bench.py / v23_ab_bench.py (셋업·채점·회귀·_build_v25_body 재사용 — 재구현 금지)
------------------------------------------------------------------------------
v25 측정의 결함:
  결과발표(schedule 07-27) recall 3/5 — 누락 2/5 (과생성 아님). 원인 둘:
  (D) v25 분해블록 **첫 문단**의 분해 트리거가 아직 "act on or show up for" 라
      "기다리는 결과 확인" 을 분해 대상에서 제외. line5(C)만 고치고 첫 문단은 누락 — 불일치.
  (E) flash-lite 가 긴 표를 끝까지 안 훑고 상단 몇 행에서 멈춤.
본 실험 v26 = v25 + D·E 로 recall 을 올리되, v25 의 강점(span 오용 0·과생성 0·기획서/산출물
recall·단순캡처 과분해 0)을 안 깨는지 본다.

프로덕션 충실 재현 (drift 0)
------------------------------------------------------------------------------
- v25 body = _build_v25_body(v22_body)  (v22 + A·B replace + 분해블록 C-교체 삽입, surgical-verified).
- v26 body = 그 v25 body 에서 분해블록 첫 문단의 아래 2곳만 교체/삽입. 그 외 0바이트 변경.
    지점 D: 첫 문단 분해 트리거 문장 교체 (act on/show up for → + wait on and check).
    지점 E: 지점 D 문장 바로 뒤(같은 첫 문단 끝)에 완전 스캔 문장 1개 추가.
  → D 1회 replace(= D_BEFORE → D_AFTER + ' ' + E_ADD) 외 단 1바이트도 안 건드림을
    _assert_surgical_v26 로 역연산 검증(결과가 v25 와 정확히 일치).
- line5 문단(C)·bullet 들은 v25 그대로 유지. 첫 문단만 위로 바뀐다.
- function schema / 시간컨텍스트(2026-06-19 15:38 KST) / temperature 0.3 / max_output_tokens 1024 /
  thinking_budget 0 / Vertex AI(global) / tool mode=ANY / 이미지 inline / finalizeAnalysis 1-shot
  — 전부 production·선행과 동일 (config 는 production 그대로, 상향 없음).

문구 출처
------------------------------------------------------------------------------
지점 D·E 의 before/after 는 부모가 정확히 명세함. v22/v25 문체(em-dash 설명체)에 맞춘 미세
조정만, 의미·판별기준 변경 없음, 화면 키워드(결과/발표/합격/대회 등) 추가 없음(overfit 금지).
Gemini 3 가이드(문서 전체 synthesize·flash-lite explicit decomposition) + skill-creator
(undertrigger 방지·explain-why) 기반.

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/v26_ab_bench.py
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

# --- 선행 실험에서 v25 body 빌드 + 8축 채점 + 회귀이미지 재사용 (재구현 금지) ---
sys.path.insert(0, str(Path(__file__).parent))
from v25_ab_bench import _build_v25_body  # noqa: E402
from v23_ab_bench import (  # noqa: E402
    _build_v23_body,
    score_dacon,
    aggregate,
    CORE,
    REGRESSION_DIR,
    REGRESSION_IMAGES,
    N_REGRESSION_RUNS,
)


DACON_IMAGE = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 8  # recall 이 핵심 지표라 noise 줄이게 각 8회.

# 재현성: 2026-06-19 (금) 15:38 KST 고정 (선행과 동일).
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))
AGENT_LOCATION = "global"


# ---------------------------------------------------------------------------
# 지점 D — 분해블록 첫 문단의 분해 트리거 문장 교체. 부모 명세 그대로.
# (v25 분해블록 첫 문단의 마지막 문장. line5 문단·bullet 은 건드리지 않는다.)
# ---------------------------------------------------------------------------
_D_BEFORE = (
    "turn each row the user must personally act on or show up for into its own instance, "
    "so each easy-to-miss deadline can resurface on its own."
)
_D_AFTER = (
    "turn each row that is the user's own — one they must act on, show up for, or wait on "
    "and check — into its own instance, so each easy-to-miss moment can resurface on its own."
)

# ---------------------------------------------------------------------------
# 지점 E — 완전 스캔 문장. 부모 명세 그대로. 지점 D AFTER 문장 끝에 이어서(같은 첫 문단 끝) 한 문장.
# ---------------------------------------------------------------------------
_E_ADD = (
    "Read the table or list through to its end before finalizing — the rows worth keeping are "
    "spread across it, not just at the top, so walk every row once rather than stopping after "
    "the first you recognize."
)


def _build_v26_body(v22_body: str) -> str:
    """v25 body 에서 분해블록 첫 문단의 트리거 문장 교체(D) + 완전 스캔 문장 삽입(E).

    v26 = v25 + (D_BEFORE → D_AFTER + ' ' + E_ADD) 단 1회 replace. 그 외 0바이트 변경.
    surgical 역연산 검증(결과가 v25 와 정확히 일치) 포함.
    """
    v25_body = _build_v25_body(v22_body)  # surgical-verified inside (선행)

    c = v25_body.count(_D_BEFORE)
    if c != 1:
        raise RuntimeError(f"v26 anchor D not unique in v25 body (count={c})")

    d_plus_e = f"{_D_AFTER} {_E_ADD}"
    v26_body = v25_body.replace(_D_BEFORE, d_plus_e, 1)

    _assert_surgical_v26(v25_body, v26_body, d_plus_e)
    return v26_body, v25_body


def _assert_surgical_v26(v25_body: str, v26_body: str, d_plus_e: str) -> None:
    """v26 = v25 + (D_BEFORE→D_AFTER+E_ADD) 외 0바이트 변경임을 역연산으로 검증.

    역연산: D_AFTER+E_ADD → D_BEFORE 복원 → v25 와 정확히 일치해야 함.
    """
    rebuilt = v26_body.replace(d_plus_e, _D_BEFORE, 1)
    if rebuilt != v25_body:
        for k, (a, b) in enumerate(zip(rebuilt, v25_body)):
            if a != b:
                ctx = max(0, k - 40)
                raise RuntimeError(
                    f"v26 NOT surgical: first diff at char {k}\n"
                    f"  rebuilt(v26->): ...{rebuilt[ctx:k+40]!r}\n"
                    f"  v25          : ...{v25_body[ctx:k+40]!r}"
                )
        raise RuntimeError(
            f"v26 NOT surgical: length mismatch rebuilt={len(rebuilt)} v25={len(v25_body)}"
        )


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


def run_once(client, model, system_prompt, image) -> dict:
    """production config 그대로: thinking_budget=0, max_output_tokens=1024, temp 0.3."""
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=1024,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
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


def run_arm(client, model, body, label, file_prefix) -> list[dict]:
    runs = []
    print(f"\n=== ARM {label}  (prompt_len={len(body)}) ===", file=sys.stderr)
    for i in range(1, N_RUNS + 1):
        try:
            r = run_once(client, model, body, DACON_IMAGE)
        except Exception as e:  # noqa: BLE001
            r = {"error": f"{type(e).__name__}: {e}"}
        r["run"] = i
        r["arm"] = label
        r["config"] = {"thinking_budget": 0, "max_output_tokens": 1024}
        (RESULTS_DIR / f"{file_prefix}_run_{i}.json").write_text(
            json.dumps(r, ensure_ascii=False, indent=2)
        )
        if "output" in r:
            sc = score_dacon(r["output"])
            r["score"] = sc
            print(f"[{label} run {i}] {r.get('latency_ms')}ms  finish={r.get('finish_reason')}  "
                  f"n={sc['n']}  recall={sc['recall']}/3  "
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


def run_regression(client, model, v25_body, v26_body) -> list[dict]:
    """단순 캡처 과분해 회귀: v25 vs v26 각 N_REGRESSION_RUNS 회 instance 수 비교.

    완전 스캔(E) 지시가 단순 캡처(표 아님)를 과분해하지 않는지 검증.
    """
    print("\n=== REGRESSION (단순 캡처 과분해 체크: v25 vs v26) ===", file=sys.stderr)
    rows = []
    for fname, desc in REGRESSION_IMAGES:
        img = REGRESSION_DIR / fname
        entry = {"image": fname, "desc": desc, "v25_counts": [], "v26_counts": [],
                 "v25_runs": [], "v26_runs": []}
        if not img.exists():
            entry["error"] = "image not found"
            rows.append(entry)
            print(f"  [SKIP] {fname} not found", file=sys.stderr)
            continue
        for body, key in ((v25_body, "v25"), (v26_body, "v26")):
            for _ in range(N_REGRESSION_RUNS):
                try:
                    r = run_once(client, model, body, img)
                except Exception as e:  # noqa: BLE001
                    r = {"error": f"{type(e).__name__}: {e}"}
                if "output" in r:
                    insts = r["output"].get("intent_instances", []) or []
                    entry[f"{key}_counts"].append(len(insts))
                    entry[f"{key}_runs"].append({
                        "n": len(insts),
                        "types": [x.get("intent_type") for x in insts],
                        "titles": [x.get("payload", {}).get("title") for x in insts],
                    })
                else:
                    entry[f"{key}_counts"].append(None)
                    entry[f"{key}_runs"].append({"error": r.get("error")})
        v25c = [c for c in entry["v25_counts"] if c is not None]
        v26c = [c for c in entry["v26_counts"] if c is not None]
        entry["v25_avg"] = round(sum(v25c) / len(v25c), 2) if v25c else None
        entry["v26_avg"] = round(sum(v26c) / len(v26c), 2) if v26c else None
        print(f"  {desc[:24]:24s}  v25 n={entry['v25_counts']} (avg {entry['v25_avg']})  "
              f"v26 n={entry['v26_counts']} (avg {entry['v26_avg']})", file=sys.stderr)
        rows.append(entry)
    return rows


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
    v26_body, v25_body = _build_v26_body(v22_body)  # both surgical-verified inside

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    (RESULTS_DIR / "v26_prompt.txt").write_text(v26_body)

    print(f"model={model}  base={ACTIVE_PROMPT.name}  transport=vertex/{AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"v22_len={len(v22_body)}  v25_len={len(v25_body)}  v26_len={len(v26_body)}  "
          f"delta(v26-v25)=+{len(v26_body)-len(v25_body)}", file=sys.stderr)
    print("surgical check: PASS (v26 = v25 + single D-replace(+E append), verified by reverse-op)",
          file=sys.stderr)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)

    # baseline v25 도 이번 세션 재측정 (파일명 v25_base_v26run_*).
    v25_runs = run_arm(client, model, v25_body, "v25(baseline)", "v25_base_v26run")
    v26_runs = run_arm(client, model, v26_body, "v26", "v26")
    regression = run_regression(client, model, v25_body, v26_body)

    agg = {"v25": aggregate(v25_runs), "v26": aggregate(v26_runs)}
    print("\n=== AGGREGATE (v25 baseline vs v26) ===", file=sys.stderr)
    print(json.dumps(agg, ensure_ascii=False, indent=2), file=sys.stderr)

    summary = {
        "meta": {
            "experiment": "v26 — 분해블록 첫 문단 트리거 확장(D: +wait-on-and-check) + "
                          "완전 스캔 문장 추가(E). v25 결과발표 recall 누락 2/5 회복 시도.",
            "model": model,
            "base_prompt": ACTIVE_PROMPT.name,
            "v25": "v22 body + A·B replace + block(C-replaced) insert (surgical-verified)",
            "v26": "v25 body + single D-replace(D_BEFORE -> D_AFTER + ' ' + E_ADD) "
                   "(surgical-verified, reverse-op == v25)",
            "config": {"thinking_budget": 0, "max_output_tokens": 1024, "temperature": 0.3,
                       "transport": f"vertex/{AGENT_LOCATION}", "image": "inline_base64"},
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs_per_arm": N_RUNS,
            "n_regression_runs": N_REGRESSION_RUNS,
            "dacon_image": str(DACON_IMAGE),
            "v22_len": len(v22_body),
            "v25_len": len(v25_body),
            "v26_len": len(v26_body),
            "core_targets": {k: {kk: vv for kk, vv in v.items() if kk != "kw"} for k, v in CORE.items()},
        },
        "aggregate": agg,
        "dacon": {"v25": v25_runs, "v26": v26_runs},
        "regression": regression,
    }
    (RESULTS_DIR / "v26_ab_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULTS_DIR}/v26_ab_summary.json + v26_run_*.json + v25_base_v26run_*.json + v26_prompt.txt",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
