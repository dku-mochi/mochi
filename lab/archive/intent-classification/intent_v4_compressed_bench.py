#!/usr/bin/env python3
"""옵션 A: v4 prompt + fhd_jpeg_q60 결합 측정.

v4 의 라벨 품질을 유지하면서 이미지 압축 (max edge 1920px, JPEG q=60) 으로
latency 비용을 상쇄할 수 있는지 검증. 8장만 돌려 latency 분포 + 후보 변동
확인.
"""

import io
import json
import statistics
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types

from intent_use_case_bench import MODEL, SCREENSHOT_DIR, SYSTEM_PROMPT, RESPONSE_SCHEMA
from intent_preprocess_bench import resize_and_compress


RESULT_PATH = Path(__file__).parent / "intent_v4_compressed_results.json"


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
        prompt = "이 스크린샷에 대한 use case 후보 3개를 생성하세요.\nJSON 만 응답.\n"

        t0 = time.perf_counter()
        resp = client.models.generate_content(model=MODEL, contents=[part, prompt], config=cfg)
        latency_ms = (time.perf_counter() - t0) * 1000

        try:
            parsed = json.loads(resp.text)
        except json.JSONDecodeError:
            parsed = {"candidates": [], "top_candidate_is_dominant": False, "_raw": resp.text}

        top = parsed["candidates"][0] if parsed.get("candidates") else {}
        row = {
            "file": path.name,
            "bytes": len(data),
            "latency_ms": round(latency_ms, 1),
            "top_label": top.get("label"),
            "top_intent": top.get("intent"),
            "top_likelihood": top.get("likelihood"),
            "dominant": parsed.get("top_candidate_is_dominant"),
            "candidates": parsed.get("candidates", []),
        }
        results.append(row)
        print(
            f"[{i}/{total}] {path.name} {len(data)//1024:>4}KB {latency_ms:>7.1f}ms  "
            f"top={top.get('label')}/{top.get('intent')} L={top.get('likelihood')} "
            f"dom={parsed.get('top_candidate_is_dominant')}",
            file=sys.stderr,
        )

    latencies = [r["latency_ms"] for r in results]
    bytes_list = [r["bytes"] for r in results]
    summary = {
        "preprocess": "fhd_jpeg_q60",
        "prompt_version": "v4",
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
        "results": results,
    }
    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)
    print("\n=== latency ===", file=sys.stderr)
    print(json.dumps(summary["latency_ms"], indent=2), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
