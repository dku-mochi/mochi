#!/usr/bin/env python3
"""dacon "일정" 표 스크린샷에 대한 프로덕션 intent 추출(v22) 실측 벤치.

목적
----
프로덕션 prompt(`classify_and_act@v22`) + finalizeAnalysis function schema + flash-lite 가
"마감일이 여러 개인 일정 표" 스크린샷을 행 단위로 분해하는지 **실제로 측정**한다.
골든 기대치와 비교해 분해도/Recall/Precision/날짜정확도/type/span/노이즈/needs_review 8축을 채점한다.

프로덕션 충실 재현 (drift 제거)
-------------------------------
- system prompt: `ACTIVE_PROMPT.body` 를 production 모듈에서 **직접 import** (복붙 금지).
- function schema: `_FINALIZE_PARAMS` 를 production `gemini_agent_client` 에서 **직접 import**.
- 시간 컨텍스트: production `_korea_time_context()` 를 import 해 now 를 2026-06-19 15:38+09:00 으로 고정.
- generation config: production `_call()` 과 동일 — temperature=0.3, max_output_tokens=1024,
  thinking_budget=0, tools=[finalizeAnalysis], tool_config function_calling mode=ANY.
- 모델: `.env` 의 GEMINI_MODEL (= gemini-3.1-flash-lite).

프로덕션과 의도적으로 다른 점 (task 지시 + 환경 제약)
----------------------------------------------------
- 클라이언트: **production 과 동일하게 Vertex AI** (`vertexai=True`, project=.env GOOGLE_CLOUD_PROJECT,
  location=production 의 gemini_agent_location="global", ADC 인증)로 호출한다.
  ※ task 는 원래 .env 의 GEMINI_API_KEY(AI Studio)를 쓰라고 했으나, 그 키가 묶인 GCP 프로젝트에서
    Generative Language API 가 비활성/차단(API_KEY_SERVICE_BLOCKED·SERVICE_DISABLED)이라 AI Studio
    경로는 호출 불가다. Vertex 는 production 이 실제로 쓰는 transport 라 오히려 충실도가 더 높다
    (AI Studio↔Vertex 분기는 측정 목표가 아니라 수단이었음). 이미지는 task 허용대로 로컬 inline(base64).
- 도구: production agent loop 는 finalizeAnalysis + 4개 context tool 을 함께 제공(mode=ANY 라
  findReferenceUrls 등을 먼저 부를 수 있음). 본 벤치는 **추출 품질** 단일 측정이 목적이고 외부
  tool(Tavily/Naver)을 라이브로 못 돌리므로, tool 목록을 finalizeAnalysis 1개로 두어 1-shot
  구조화 추출을 강제한다. 즉 "분류·날짜·분해" 능력만 격리 측정한다(링크 부착은 별개 축).

실행
----
    uv run --directory mochi-backend python ../lab/active/dacon-schedule-extraction/dacon_schedule_bench.py

(mochi-backend uv 환경에서 돌려야 production 모듈 import 가능. .env 자동 로드.)
"""

import base64
import json
import mimetypes
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from google import genai
from google.genai import types

# --- production 모듈 직접 import (read-only) — prompt/schema/time-ctx drift 0 ---
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE, _FINALIZE_PARAMS
from app.modules.agent.application.orchestrator import _korea_time_context


IMAGE_PATH = Path("/Users/jun/Downloads/스크린샷, 2026-06-19 오후 3.38.12.png")
RESULTS_DIR = Path(__file__).parent / "results"
N_RUNS = 5

# 재현성: 상대/마감 날짜 해석 기준 — 2026-06-19 (금) 15:38 KST 로 고정.
PINNED_NOW = datetime(2026, 6, 19, 15, 38, 0, tzinfo=ZoneInfo("Asia/Seoul"))


# production 의 gemini_agent_location 기본값 (Vertex 호출 리전). config.py 정본과 동치.
AGENT_LOCATION = "global"


def _load_env() -> None:
    """mochi-backend/.env 에서 GOOGLE_CLOUD_PROJECT / GEMINI_MODEL 만 읽어 환경변수로 (값 미출력)."""
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
    """production `_initial_user_text` 의 이미지 캡처 분기 모양을 그대로 재현 (시간컨텍스트 고정)."""
    blocks = [
        _korea_time_context(PINNED_NOW),  # production 포맷 그대로, now 만 고정
        "첨부된 스크린샷/이미지를 함께 분석하세요.",
    ]
    return "\n\n".join(blocks)


def _image_part() -> types.Part:
    mime = mimetypes.guess_type(str(IMAGE_PATH))[0] or "image/png"
    data = IMAGE_PATH.read_bytes()
    return types.Part.from_bytes(data=data, mime_type=mime)


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


def run_once(client: genai.Client, model: str, system_prompt: str) -> dict:
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
        types.Content(role="user", parts=[types.Part(text=_build_user_message()), _image_part()])
    ]
    t0 = time.perf_counter()
    resp = client.models.generate_content(model=model, contents=contents, config=cfg)
    latency_ms = round((time.perf_counter() - t0) * 1000, 1)

    args = _extract_finalize_args(resp)
    if args is None:
        return {"latency_ms": latency_ms, "error": "no finalizeAnalysis call",
                "raw_text": getattr(resp, "text", None)}
    return {"latency_ms": latency_ms, "output": args}


def main() -> int:
    _load_env()
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    model = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-lite")
    if not project:
        print("BLOCKER: GOOGLE_CLOUD_PROJECT not found in env/.env", file=sys.stderr)
        return 2
    if not IMAGE_PATH.exists():
        print(f"BLOCKER: image not found: {IMAGE_PATH}", file=sys.stderr)
        return 2

    print(f"model={model}  prompt={ACTIVE_PROMPT.name}  runs={N_RUNS}", file=sys.stderr)
    print(f"transport=vertex  location={AGENT_LOCATION}", file=sys.stderr)
    print(f"pinned_now={PINNED_NOW.isoformat()}", file=sys.stderr)
    print(f"system_prompt_len={len(ACTIVE_PROMPT.body)} chars", file=sys.stderr)

    # production transport: Vertex AI + ADC (gemini_agent_client._shared_client 와 동일 구성).
    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    runs = []
    for i in range(1, N_RUNS + 1):
        try:
            r = run_once(client, model, ACTIVE_PROMPT.body)
        except Exception as e:  # noqa: BLE001 — 벤치, 어떤 SDK 에러든 run 단위로 기록
            r = {"error": f"{type(e).__name__}: {e}"}
        r["run"] = i
        runs.append(r)

        out_path = RESULTS_DIR / f"run_{i}.json"
        out_path.write_text(json.dumps(r, ensure_ascii=False, indent=2))

        if "output" in r:
            out = r["output"]
            insts = out.get("intent_instances", [])
            print(f"\n[run {i}] {r.get('latency_ms')}ms  instances={len(insts)}  "
                  f"needs_review={out.get('needs_review')}  "
                  f"review_options={len(out.get('review_options', []))}  "
                  f"category={out.get('category')!r}", file=sys.stderr)
            for ins in insts:
                p = ins.get("payload", {})
                date_str = p.get("date") or p.get("deadline") or "-"
                if p.get("time"):
                    date_str = f"{date_str} {p['time']}"
                if p.get("end_date"):
                    date_str = f"{date_str} ~ {p['end_date']}" + (f" {p.get('end_time')}" if p.get("end_time") else "")
                print(f"    - {ins.get('intent_type'):8s} | {p.get('title','?'):28s} | {date_str}",
                      file=sys.stderr)
        else:
            print(f"\n[run {i}] ERROR: {r.get('error')}", file=sys.stderr)

    summary = {
        "meta": {
            "model": model,
            "prompt_version": ACTIVE_PROMPT.name,
            "pinned_now": PINNED_NOW.isoformat(),
            "n_runs": N_RUNS,
            "image": str(IMAGE_PATH),
            "client": f"vertex(project,location={AGENT_LOCATION})_inline_base64",
            "tools_offered": [_FINALIZE],
            "note": "production parity: prompt/schema/time-ctx/config imported from app.modules.agent",
        },
        "runs": runs,
    }
    (RESULTS_DIR / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULTS_DIR}/summary.json + run_*.json", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
