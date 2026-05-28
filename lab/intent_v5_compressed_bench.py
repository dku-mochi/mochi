#!/usr/bin/env python3
"""v5 prompt + fhd_jpeg_q60 결합 측정.

v5 변경점:
- Framing reframe: "스크린샷 찍기" → "무언가를 모찌에 남기는 기록 행위"
- Multi-intent 허용: 후보별 독립 likelihood (합 ≠ 1.0)
- 새 boolean: dominant_single_intent / likely_multi_intent
"""

import json
import statistics
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types

from intent_use_case_bench import MODEL, SCREENSHOT_DIR, SYSTEM_PROMPT, RESPONSE_SCHEMA
from intent_preprocess_bench import resize_and_compress


RESULT_PATH = Path(__file__).parent / "intent_v5_compressed_results.json"


def main() -> int:
    screenshots = sorted(SCREENSHOT_DIR.glob("*.PNG")) + sorted(SCREENSHOT_DIR.glob("*.png"))
    client = genai.Client(vertexai=True, location="global")

    results = []
    total = len(screenshots)
    for i, path in enumerate(screenshots, 1):
        data, mime = resize_and_compress(path, 1920, "JPEG", 60)
        cfg = types.GenerateContentConfig(
            system_instruction=SYSTEM_PROMPT,
            temperature=0.3,
            max_output_tokens=1024,
            response_mime_type="application/json",
            response_schema=RESPONSE_SCHEMA,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
        )
        part = types.Part.from_bytes(data=data, mime_type=mime)
        prompt = "이 기록에 대한 use case 후보 3개를 생성하세요.\nJSON 만 응답.\n"

        t0 = time.perf_counter()
        resp = client.models.generate_content(model=MODEL, contents=[part, prompt], config=cfg)
        latency_ms = (time.perf_counter() - t0) * 1000

        try:
            parsed = json.loads(resp.text)
        except json.JSONDecodeError:
            parsed = {"candidates": [], "_raw": resp.text}

        cands = parsed.get("candidates", [])
        row = {
            "file": path.name,
            "bytes": len(data),
            "latency_ms": round(latency_ms, 1),
            "dominant_single_intent": parsed.get("dominant_single_intent"),
            "likely_multi_intent": parsed.get("likely_multi_intent"),
            "candidates": cands,
        }
        results.append(row)
        top_str = " | ".join(
            f"{c['label']}({c['likelihood']:.2f},{c['intent']})" for c in cands
        )
        flags = []
        if parsed.get("dominant_single_intent"):
            flags.append("DOM")
        if parsed.get("likely_multi_intent"):
            flags.append("MULTI")
        flag_str = ",".join(flags) or "-"
        print(
            f"[{i}/{total}] {path.name} {len(data)//1024:>4}KB {latency_ms:>7.1f}ms [{flag_str}]\n"
            f"   {top_str}",
            file=sys.stderr,
        )

    latencies = [r["latency_ms"] for r in results]
    bytes_list = [r["bytes"] for r in results]
    summary = {
        "prompt_version": "v5",
        "preprocess": "fhd_jpeg_q60",
        "n": len(results),
        "latency_ms": {
            "min": round(min(latencies), 1),
            "p50": round(statistics.median(latencies), 1),
            "mean": round(statistics.mean(latencies), 1),
            "max": round(max(latencies), 1),
        },
        "bytes": {
            "min": min(bytes_list),
            "mean": int(statistics.mean(bytes_list)),
            "max": max(bytes_list),
        },
        "n_dominant": sum(1 for r in results if r.get("dominant_single_intent")),
        "n_multi_intent": sum(1 for r in results if r.get("likely_multi_intent")),
        "results": results,
    }
    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)
    print(json.dumps(summary["latency_ms"], indent=2), file=sys.stderr)
    print(f"dominant_single_intent: {summary['n_dominant']}/{len(results)}", file=sys.stderr)
    print(f"likely_multi_intent:    {summary['n_multi_intent']}/{len(results)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
