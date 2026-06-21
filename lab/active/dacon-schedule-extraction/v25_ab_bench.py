#!/usr/bin/env python3
"""v23 vs v25 A/B — schedule 정의 2지점 + 분해블록 1지점을 "waiting-on-an-outcome" 으로 확장.

선행: v23_ab_bench.py / v24b_config_bench.py (셋업·채점·회귀 재사용)
------------------------------------------------------------------------------
v23 측정의 두 결함:
  (1) 결과발표(schedule 07-27) 0/5 — "내가 직접 행동하지 않는" 결과 발표를 schedule 로 못 잡음.
  (2) 우산 span 오용 5/5 — "대회 참가 기간"(여러 마감을 담는 기간) 을 하나의 schedule span 으로 오인.
v24b(config 상향)는 별개 변수. 본 실험은 **프롬프트 3지점 surgical 교체**로 두 결함을 동시에 겨냥한다:
  - A·B: schedule 정의를 (a) "사용자가 기다리던 결과가 도착하는 순간"도 schedule 로 포함하도록 확장,
         (b) "여러 개별 날짜를 담는 기간"은 span 이 아님을 명시(우산 span 오용 차단).
  - C: 분해블록 line 5 를, 제3자 process 와 "사용자가 기다리던 outcome 도착" 을 구분하도록 교체.

프로덕션 충실 재현 (drift 0)
------------------------------------------------------------------------------
- v23 body = production ``ACTIVE_PROMPT.body``(=v22) + 선행 _V23_BLOCK 1개 surgical 삽입.
- v25 body = v22 body 에서 지점 A·B `.replace()` 교체 + 분해블록(C 로 교체된 line5)을 v23 앵커에 삽입.
  → A·B·블록삽입 외 단 1바이트도 안 건드림을 _assert_surgical_v25 로 역연산 검증.
- function schema(_FINALIZE/_FINALIZE_PARAMS) / 시간컨텍스트(2026-06-19 15:38 KST,
  _korea_time_context) / temperature 0.3 / max_output_tokens 1024 / thinking_budget 0 /
  Vertex AI(global) / tool mode=ANY / 이미지 inline / finalizeAnalysis 1-shot
  — 전부 production·선행과 동일 (config 는 production 그대로, 상향 없음).

문구 출처
------------------------------------------------------------------------------
지점 A·B·C 의 before/after 는 부모가 정확히 명세함. 본 스크립트는 그 after 를 v22 문체(em-dash
설명체)에 맞춰 그대로 적용만 한다 — 의미·판별기준 변경 없음, 화면 키워드(결과/발표/합격/대회 등)
추가 없음(overfit 금지). Gemini 3 가이드(넓은 부정지시 제거→scoped 긍정기준) + skill-creator
(criteria-over-examples, explain-why) 기반.

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/v25_ab_bench.py
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

# --- 선행 실험에서 v23 body 빌드 + 8축 채점 + 회귀이미지 재사용 (재구현 금지) ---
sys.path.insert(0, str(Path(__file__).parent))
from v23_ab_bench import (  # noqa: E402
    _build_v23_body,
    _V23_BLOCK,
    _V23_ANCHOR,
    score_dacon,
    aggregate,
    CORE,
    REGRESSION_DIR,
    REGRESSION_IMAGES,
    N_REGRESSION_RUNS,
)


DACON_IMAGE = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 5

# 재현성: 2026-06-19 (금) 15:38 KST 고정 (선행과 동일).
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))
AGENT_LOCATION = "global"


# ---------------------------------------------------------------------------
# 지점 A — schedule 정의 첫 문장 (system_prompts.py:77-79). 부모 명세 그대로.
# ---------------------------------------------------------------------------
_A_BEFORE = (
    "- schedule — MOCHI puts it on the calendar and reminds before the moment. "
    "Choose it when a specific date/time is the point and the user must be somewhere or act then."
)
_A_AFTER = (
    "- schedule — MOCHI puts it on the calendar and reminds before the moment. "
    "Choose it when a specific date/time is the point and MOCHI reminding the user then is "
    "something they'd be grateful for. That holds not only when they must be somewhere or act "
    "at that time, but also when they're waiting on an outcome that lands then and will want to "
    "check it the moment it does."
)

# ---------------------------------------------------------------------------
# 지점 B — schedule 정의 span 문장 (system_prompts.py:80-82). 부모 명세 그대로.
# ---------------------------------------------------------------------------
_B_BEFORE = (
    "Some events occupy a span rather than a moment — a trip, a course the user attends from a "
    "start day to an end day; that is still one schedule, and it is past only when its end has "
    "passed."
)
_B_AFTER = (
    "Some events occupy a span rather than a moment — a trip, a stay, a multi-day program the "
    "user is continuously engaged in from a start day to an end day; that is still one schedule, "
    "past only when its end has passed. But a period that merely contains several separate dates "
    "or deadlines is not such a span: there is no single stretch the user is occupied with, only "
    "individual moments inside it, and each of those is its own instance. The containing period "
    "itself carries no moment for MOCHI to remind about, so it is not a schedule."
)

# ---------------------------------------------------------------------------
# 지점 C — v23 분해블록 line 5 문단 교체. 부모 명세 그대로.
# v23 블록의 첫 문단 + 첫 bullet 은 그대로, line5 문단만 교체해 v25 블록을 만든다.
# ---------------------------------------------------------------------------
_C_BEFORE = (
    "Making an instance per row does not mean every row. A row earns an instance only if it is "
    "the user's own future action; the rest belong in the summary, not as instances — because an "
    "instance the user can't act on is just noise that buries the ones they can. Three kinds stay "
    "in the summary: rows already in the past (their moment is gone, like any past event), rows "
    "that are someone else's move to make (a third party's or the organizer's voting, judging, "
    "review, or announcement — the user only waits on these), and a single span that merely wraps "
    "the others as background (an umbrella period the individual rows already live inside)."
)
_C_AFTER = (
    "Making an instance per row does not mean every row. A row earns an instance when it is the "
    "user's own future action, or a moment they're waiting on and will want to check — the rest "
    "belong in the summary, not as instances, because an instance the user has nothing to do with "
    "is just noise that buries the ones they can use. Three kinds stay in the summary: rows "
    "already in the past (their moment is gone, like any past event); rows that are purely someone "
    "else's process to run, where the user has no action to take and no outcome to check (a third "
    "party's or the organizer's internal voting, judging, or review step) — but a moment when an "
    "outcome the user has been waiting on lands is theirs to check, so that stays a schedule, not "
    "background; and a single period that merely wraps the others as background (an umbrella "
    "window the individual rows already live inside), which is not the user's own span and stays "
    "in the summary while its individual rows each become instances."
)


def _build_v25_block() -> str:
    """v23 블록의 line5 문단만 _C_AFTER 로 교체한 v25 블록 (앵커 포함 형태)."""
    if _V23_BLOCK.count(_C_BEFORE) != 1:
        raise RuntimeError(f"C_BEFORE not unique in v23 block (count={_V23_BLOCK.count(_C_BEFORE)})")
    return _V23_BLOCK.replace(_C_BEFORE, _C_AFTER, 1)


def _build_v25_body(v22_body: str) -> str:
    """v22 body 에 A·B 교체 + v25 분해블록 삽입. surgical 역연산 검증 포함."""
    for name, before in (("A", _A_BEFORE), ("B", _B_BEFORE)):
        c = v22_body.count(before)
        if c != 1:
            raise RuntimeError(f"v25 anchor {name} not unique (count={c})")
    if v22_body.count(_V23_ANCHOR) != 1:
        raise RuntimeError(f"v25 block anchor not unique (count={v22_body.count(_V23_ANCHOR)})")

    v25_block = _build_v25_block()
    body = v22_body.replace(_A_BEFORE, _A_AFTER, 1)
    body = body.replace(_B_BEFORE, _B_AFTER, 1)
    body = body.replace(_V23_ANCHOR, v25_block, 1)

    _assert_surgical_v25(v22_body, body, v25_block)
    return body


def _assert_surgical_v25(v22_body: str, v25_body: str, v25_block: str) -> None:
    """v25 = v22 + (A→A', B→B', 블록삽입) 외 0바이트 변경임을 역연산으로 검증.

    역연산: 삽입블록 제거 → A'→A 복원 → B'→B 복원 → v22 와 정확히 일치해야 함.
    """
    inserted = v25_block[len(_V23_ANCHOR):]  # 앵커 뒤 새로 들어간 부분
    rebuilt = v25_body.replace(inserted, "", 1)        # 블록 삽입 되돌리기
    rebuilt = rebuilt.replace(_A_AFTER, _A_BEFORE, 1)  # A 교체 되돌리기
    rebuilt = rebuilt.replace(_B_AFTER, _B_BEFORE, 1)  # B 교체 되돌리기
    if rebuilt != v22_body:
        # 어디가 어긋났는지 첫 차이 위치 표시
        for k, (a, b) in enumerate(zip(rebuilt, v22_body)):
            if a != b:
                ctx = max(0, k - 40)
                raise RuntimeError(
                    f"v25 NOT surgical: first diff at char {k}\n"
                    f"  rebuilt: ...{rebuilt[ctx:k+40]!r}\n"
                    f"  v22    : ...{v22_body[ctx:k+40]!r}"
                )
        raise RuntimeError(
            f"v25 NOT surgical: length mismatch rebuilt={len(rebuilt)} v22={len(v22_body)}"
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


def run_regression(client, model, v23_body, v25_body) -> list[dict]:
    """단순 캡처 과분해 회귀: v23 vs v25 각 N_REGRESSION_RUNS 회 instance 수 비교."""
    print("\n=== REGRESSION (단순 캡처 과분해 체크: v23 vs v25) ===", file=sys.stderr)
    rows = []
    for fname, desc in REGRESSION_IMAGES:
        img = REGRESSION_DIR / fname
        entry = {"image": fname, "desc": desc, "v23_counts": [], "v25_counts": [],
                 "v23_runs": [], "v25_runs": []}
        if not img.exists():
            entry["error"] = "image not found"
            rows.append(entry)
            print(f"  [SKIP] {fname} not found", file=sys.stderr)
            continue
        for body, key in ((v23_body, "v23"), (v25_body, "v25")):
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
        v23c = [c for c in entry["v23_counts"] if c is not None]
        v25c = [c for c in entry["v25_counts"] if c is not None]
        entry["v23_avg"] = round(sum(v23c) / len(v23c), 2) if v23c else None
        entry["v25_avg"] = round(sum(v25c) / len(v25c), 2) if v25c else None
        print(f"  {desc[:24]:24s}  v23 n={entry['v23_counts']} (avg {entry['v23_avg']})  "
              f"v25 n={entry['v25_counts']} (avg {entry['v25_avg']})", file=sys.stderr)
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
    v23_body = _build_v23_body(v22_body)   # surgical-verified inside (선행)
    v25_body = _build_v25_body(v22_body)   # surgical-verified inside (본 실험)

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    (RESULTS_DIR / "v25_prompt.txt").write_text(v25_body)

    print(f"model={model}  base={ACTIVE_PROMPT.name}  transport=vertex/{AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"v22_len={len(v22_body)}  v23_len={len(v23_body)}  v25_len={len(v25_body)}  "
          f"delta(v25-v22)=+{len(v25_body)-len(v22_body)}", file=sys.stderr)
    print("surgical check: PASS (A·B replace + block insert only, verified by reverse-op)",
          file=sys.stderr)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)

    # baseline v23 도 이번 세션 재측정 (파일명 v23_base_v25run_*).
    v23_runs = run_arm(client, model, v23_body, "v23(baseline)", "v23_base_v25run")
    v25_runs = run_arm(client, model, v25_body, "v25", "v25")
    regression = run_regression(client, model, v23_body, v25_body)

    agg = {"v23": aggregate(v23_runs), "v25": aggregate(v25_runs)}
    print("\n=== AGGREGATE (v23 baseline vs v25) ===", file=sys.stderr)
    print(json.dumps(agg, ensure_ascii=False, indent=2), file=sys.stderr)

    summary = {
        "meta": {
            "experiment": "v25 — schedule 정의 A·B 교체 + 분해블록 line5(C) 교체. "
                          "waiting-on-an-outcome 회복 + 우산 span 오용 차단.",
            "model": model,
            "base_prompt": ACTIVE_PROMPT.name,
            "v23": "v22 body + single inserted block (surgical-verified)",
            "v25": "v22 body + A·B replace + block(C-replaced) insert (surgical-verified, reverse-op)",
            "config": {"thinking_budget": 0, "max_output_tokens": 1024, "temperature": 0.3,
                       "transport": f"vertex/{AGENT_LOCATION}", "image": "inline_base64"},
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs_per_arm": N_RUNS,
            "n_regression_runs": N_REGRESSION_RUNS,
            "dacon_image": str(DACON_IMAGE),
            "v22_len": len(v22_body),
            "v23_len": len(v23_body),
            "v25_len": len(v25_body),
            "core_targets": {k: {kk: vv for kk, vv in v.items() if kk != "kw"} for k, v in CORE.items()},
        },
        "aggregate": agg,
        "dacon": {"v23": v23_runs, "v25": v25_runs},
        "regression": regression,
    }
    (RESULTS_DIR / "v25_ab_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULTS_DIR}/v25_ab_summary.json + v25_run_*.json + v23_base_v25run_*.json + v25_prompt.txt",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
