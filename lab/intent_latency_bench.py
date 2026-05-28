#!/usr/bin/env python3
"""4-Intent 분류 latency 벤치 — Gemini 3.1 Flash Lite (Vertex AI).

모찌 백탭 흐름의 silent + notification fallback UX 설계를 위한 실측.
스크린샷을 받아 schedule/todo/knowledge/memo 중 하나로 분류하고
confidence + reasoning + per-call latency 를 기록한다.

사용:
  python3 intent_latency_bench.py [--thinking minimal|low|medium|high]

기본 thinking=minimal (Flash Lite 의 속도 강점 살림).
"""

import argparse
import json
import mimetypes
import statistics
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types


MODEL = "gemini-3.1-flash-lite"
SCREENSHOT_DIR = Path(__file__).parent / "screenshot"
RESULT_PATH = Path(__file__).parent / "intent_latency_results.json"

SYSTEM_PROMPT = """\
당신은 모찌(MOCHI)의 캡쳐 분류 모델이다. 사용자가 백탭으로 캡쳐한 스크린샷을 보고
다음 4-Intent 중 하나로 분류한다.

- schedule: 특정 시점에 발생/참여하는 사건 (예약, 회의, 모임, 행사, 예매)
- todo: 사용자가 *직접* 수행해야 할 작업 (구입, 답장, 신청, 처리, 시도해보기)
- knowledge: 참조용 지식·정보 (개념 설명, 가이드, 레시피, 학습 자료, 영구 가치)
- memo: 위 셋에 안 들어가는 짧은 기록, 사진 메모, 영감, 분류가 어려운 잡다

confidence (0.0-1.0) 는 분류에 대한 본인 확신.
- 0.85+ : 거의 확실
- 0.70-0.85 : 명확하지만 다른 분기 가능성도 존재
- 0.70 미만 : 모호 — 사용자에게 hint 를 요청해야 함

reasoning 은 한국어 1-2 문장으로 분류 근거.
ambiguity_axis 는 모호한 경우에만 채우고, 어떤 두 intent 사이에서 헷갈리는지 ("knowledge_vs_todo" 등).
"""

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {
            "type": "string",
            "enum": ["schedule", "todo", "knowledge", "memo"],
        },
        "confidence": {"type": "number"},
        "reasoning": {"type": "string"},
        "ambiguity_axis": {"type": "string"},
    },
    "required": ["intent", "confidence", "reasoning"],
}


def load_image(path: Path) -> types.Part:
    mime = mimetypes.guess_type(str(path))[0] or "image/png"
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)


def classify(client: genai.Client, image_path: Path, thinking: str) -> dict:
    image_part = load_image(image_path)
    prompt = (
        "이 스크린샷을 4-Intent (schedule / todo / knowledge / memo) 로 분류하세요.\n"
        "응답은 JSON 만. 다른 텍스트 없이.\n"
    )

    thinking_budget_map = {
        "minimal": 0,
        "low": 256,
        "medium": 1024,
        "high": 4096,
    }
    cfg = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT,
        temperature=0.2,
        max_output_tokens=512,
        response_mime_type="application/json",
        response_schema=RESPONSE_SCHEMA,
        thinking_config=types.ThinkingConfig(
            thinking_budget=thinking_budget_map[thinking],
        ),
    )

    t0 = time.perf_counter()
    resp = client.models.generate_content(
        model=MODEL,
        contents=[image_part, prompt],
        config=cfg,
    )
    latency_ms = (time.perf_counter() - t0) * 1000

    try:
        parsed = json.loads(resp.text)
    except json.JSONDecodeError:
        parsed = {
            "intent": "memo",
            "confidence": 0.0,
            "reasoning": "JSON parse error",
            "_raw": resp.text,
        }

    return {
        "file": image_path.name,
        "size_bytes": image_path.stat().st_size,
        "latency_ms": round(latency_ms, 1),
        "intent": parsed.get("intent"),
        "confidence": parsed.get("confidence"),
        "reasoning": parsed.get("reasoning"),
        "ambiguity_axis": parsed.get("ambiguity_axis", ""),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--thinking",
        choices=["minimal", "low", "medium", "high"],
        default="minimal",
        help="thinking budget — minimal 이 속도, high 가 품질 (Flash Lite)",
    )
    parser.add_argument("--project", default=None)
    parser.add_argument("--location", default="global")
    args = parser.parse_args()

    screenshots = sorted(SCREENSHOT_DIR.glob("*.PNG")) + sorted(SCREENSHOT_DIR.glob("*.png"))
    if not screenshots:
        print(f"No screenshots in {SCREENSHOT_DIR}", file=sys.stderr)
        return 1

    print(f"Model: {MODEL}  thinking={args.thinking}", file=sys.stderr)
    print(f"Screenshots: {len(screenshots)}", file=sys.stderr)
    print(f"Location: {args.location}\n", file=sys.stderr)

    client = genai.Client(vertexai=True, project=args.project, location=args.location)

    results = []
    for i, path in enumerate(screenshots, 1):
        print(f"[{i}/{len(screenshots)}] {path.name} …", file=sys.stderr, end=" ", flush=True)
        try:
            r = classify(client, path, args.thinking)
        except Exception as e:
            r = {
                "file": path.name,
                "error": str(e),
                "error_type": type(e).__name__,
            }
        results.append(r)
        if "error" in r:
            print(f"ERROR: {r['error_type']}", file=sys.stderr)
        else:
            print(
                f"{r['latency_ms']}ms  {r['intent']}  conf={r['confidence']}",
                file=sys.stderr,
            )

    latencies = [r["latency_ms"] for r in results if "latency_ms" in r]
    summary = {
        "model": MODEL,
        "thinking": args.thinking,
        "n": len(results),
        "n_ok": len(latencies),
        "latency_ms": {
            "min": round(min(latencies), 1) if latencies else None,
            "p50": round(statistics.median(latencies), 1) if latencies else None,
            "mean": round(statistics.mean(latencies), 1) if latencies else None,
            "max": round(max(latencies), 1) if latencies else None,
        },
        "results": results,
    }

    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)
    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
