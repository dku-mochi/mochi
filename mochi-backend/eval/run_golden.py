#!/usr/bin/env python3
"""분석 에이전트 골든 eval 러너 — production 충실 재현 (drift 0).

각 케이스의 input(text/url/user_memo/image/ocr_text/pinned_now)으로 분석 에이전트를
``finalizeAnalysis``-only 1-shot 실행하고:
- 케이스에 ``expected`` 가 있으면(Tier 1) ``eval.scorer`` 로 **결정적 채점**,
- 없으면(Tier 2 현실셋) 분석 출력만 저장 — LLM-judge workflow 가 채점한다.

## production drift 0
- system prompt = ``ACTIVE_PROMPT.body`` 직접 import (복붙 금지)
- function schema = ``_FINALIZE`` / ``_FINALIZE_PARAMS`` 직접 import
- generation config(temp 0.3 / max_output_tokens 4096 / thinking_budget 0 / mode=ANY) = production 값
  (lab/active/dacon-schedule-extraction 선례 + V25 의 1024→4096 상향 반영)
- user message = ``orchestrator._initial_user_text`` 의 블록 구조를 **pinned_now 로 재현**
  (``_initial_user_text`` 는 now 인자가 없어 실행시각을 쓰므로 직접 호출 불가 → 블록 문구를 복제;
  문구가 1바이트라도 어긋나면 drift 이므로 orchestrator 와 동일 문자열 유지)

## 한계 (의도된 단순화)
finalize-only 1-shot 이라 **tool loop(platformContext/webFetch/findReferenceUrls…)는 돌지 않는다.**
이 러너는 *분류·payload·분해 품질* 측정용이다. tool 호출 게이트(링크 회수·환각 URL)는 별도
tool-gating 케이스(orchestrator + Fake 레지스트리)에서 측정한다.

## 실행
    RUN_EVAL=1 GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \\
      python eval/run_golden.py --cases <path> [--runs N] [--out DIR]
"""

from __future__ import annotations

import argparse
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

from app.modules.agent.application.orchestrator import _korea_time_context
from app.modules.agent.infrastructure.gemini_agent_client import _FINALIZE, _FINALIZE_PARAMS
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT

# scorer 는 같은 eval/ 디렉터리 — hermetic 테스트와 동일 채점기를 공유한다.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from scorer import score_case  # noqa: E402

KST = ZoneInfo("Asia/Seoul")
AGENT_LOCATION = "global"


def _parse_now(raw: str | None) -> datetime:
    """'2026-06-19 12:16:37.807423+00' 같은 pinned_now 를 KST datetime 으로."""
    if not raw:
        return datetime.now(KST)
    s = raw.strip().replace(" ", "T", 1)
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        dt = datetime.fromisoformat(s.split(".")[0].split("+")[0])
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=KST)
    return dt.astimezone(KST)


def build_user_text(inp: dict, now: datetime) -> str:
    """orchestrator._initial_user_text 의 블록 구조를 pinned_now 로 재현 (문구 패리티)."""
    blocks = [_korea_time_context(now)]
    text = inp.get("text") or inp.get("raw_text")
    if text:
        blocks.append(f"내용:\n{text}")
    if inp.get("url"):
        blocks.append(f"URL: {inp['url']}")
    if inp.get("user_memo"):
        blocks.append(f"사용자 메모: {inp['user_memo']}")
    if inp.get("image_path"):
        blocks.append("첨부된 스크린샷/이미지를 함께 분석하세요.")
    if inp.get("ocr_text"):
        blocks.append(
            "# 화면 텍스트 (OCR)\n"
            "기기에서 화면을 기계로 읽어낸 transcript 입니다 (사용자가 직접 쓴 글이 아니라 화면에 보이던 글자). "
            "첨부 이미지와 교차확인해 항목을 빠짐없이 분해하는 데 쓰되, 이미지를 대체하지 말고 보완하세요 — "
            "오인식·잡음이 있을 수 있으니 이미지가 보여주는 근거를 우선합니다.\n" + inp["ocr_text"]
        )
    return "\n\n".join(blocks)


def _image_part(path: Path) -> types.Part:
    mime = mimetypes.guess_type(str(path))[0] or "image/jpeg"
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)


def _finalize_decl() -> types.FunctionDeclaration:
    return types.FunctionDeclaration(
        name=_FINALIZE,
        description="Emit the final structured analysis. Call exactly once when ready.",
        parameters=_FINALIZE_PARAMS,
    )


def _extract_args(resp) -> dict | None:
    for cand in getattr(resp, "candidates", None) or []:
        content = getattr(cand, "content", None)
        if content is None:
            continue
        for part in getattr(content, "parts", None) or []:
            fc = getattr(part, "function_call", None)
            if fc is not None and getattr(fc, "name", None) == _FINALIZE:
                return dict(fc.args or {})
    return None


def run_once(client, model: str, system_prompt: str, user_text: str, image_path: Path | None) -> dict:
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=4096,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        tools=[types.Tool(function_declarations=[_finalize_decl()])],
        tool_config=types.ToolConfig(function_calling_config=types.FunctionCallingConfig(mode="ANY")),
    )
    parts: list[types.Part] = [types.Part(text=user_text)]
    if image_path is not None:
        parts.append(_image_part(image_path))
    contents = [types.Content(role="user", parts=parts)]
    t0 = time.perf_counter()
    resp = client.models.generate_content(model=model, contents=contents, config=cfg)
    latency_ms = round((time.perf_counter() - t0) * 1000, 1)
    args = _extract_args(resp)
    if args is None:
        return {"latency_ms": latency_ms, "error": "no finalizeAnalysis call"}
    return {"latency_ms": latency_ms, "output": args}


def _resolve_image(inp: dict, cases_dir: Path) -> Path | None:
    rel = inp.get("image_path")
    if not rel:
        return None
    p = Path(rel) if Path(rel).is_absolute() else cases_dir / rel
    return p if p.exists() else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True, help="cases.json 경로 ({_meta?, cases:[...]} 또는 [...])")
    ap.add_argument("--runs", type=int, default=1, help="케이스당 run 수 (비결정성 aggregate)")
    ap.add_argument("--out", default=None, help="출력 디렉터리 (기본: cases 디렉터리/eval_runs)")
    args = ap.parse_args()

    if not os.environ.get("RUN_EVAL"):
        print(
            "BLOCKER: live eval 은 RUN_EVAL=1 가드가 필요하다(비용·네트워크). 의도적이면 RUN_EVAL=1 로 실행.",
            file=sys.stderr,
        )
        return 2
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    model = os.environ.get("GEMINI_MODEL", ACTIVE_PROMPT.model_target)
    if not project:
        print("BLOCKER: GOOGLE_CLOUD_PROJECT 가 설정되지 않았다.", file=sys.stderr)
        return 2

    cases_path = Path(args.cases)
    data = json.loads(cases_path.read_text())
    cases = data["cases"] if isinstance(data, dict) else data
    cases_dir = cases_path.parent
    out_dir = Path(args.out) if args.out else cases_dir / "eval_runs"
    out_dir.mkdir(parents=True, exist_ok=True)

    client = genai.Client(vertexai=True, project=project, location=AGENT_LOCATION)
    print(f"model={model} base={ACTIVE_PROMPT.name} cases={len(cases)} runs={args.runs}", file=sys.stderr)

    results = []
    for c in cases:
        cid = c.get("id", "?")
        inp = c["input"]
        now = _parse_now(inp.get("pinned_now"))
        user_text = build_user_text(inp, now)
        img = _resolve_image(inp, cases_dir)
        runs = []
        for _ in range(1, args.runs + 1):
            try:
                rr = run_once(client, model, ACTIVE_PROMPT.body, user_text, img)
            except Exception as e:  # noqa: BLE001
                rr = {"error": f"{type(e).__name__}: {e}"}
            if "output" in rr and c.get("expected"):
                rr["score"] = score_case(rr["output"], c["expected"])
            runs.append(rr)
        rec: dict = {"id": cid, "runs": runs}
        if c.get("expected"):
            passes = [x["score"]["passed"] for x in runs if x.get("score")]
            graded = [p for p in passes if p is not None]
            rec["pass_rate"] = round(sum(1 for p in graded if p) / len(graded), 2) if graded else None
        (out_dir / f"{cid}.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2))
        results.append(rec)
        line = f"[{cid}]"
        if rec.get("pass_rate") is not None:
            line += f" pass_rate={rec['pass_rate']}"
        print(line, file=sys.stderr)

    summary = {
        "model": model,
        "base_prompt": ACTIVE_PROMPT.name,
        "n_cases": len(cases),
        "runs_per_case": args.runs,
        "results": results,
    }
    (out_dir / "_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))

    scored = [r for r in results if r.get("pass_rate") is not None]
    if scored:
        mean = round(sum(r["pass_rate"] for r in scored) / len(scored), 3)
        print(f"\n=== Tier1 aggregate: {len(scored)} cases, mean pass_rate={mean} ===", file=sys.stderr)
    print(f"→ {out_dir}/", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
