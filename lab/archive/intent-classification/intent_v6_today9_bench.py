#!/usr/bin/env python3
"""v6 벤치를 2026-05-27 추가된 9장 한정으로 실행 (별도 결과 파일).

intent_v6_compressed_bench 의 derive_flags / 전처리 / 프롬프트 / 스키마는
그대로 재사용하고, 입력 셋과 결과 경로만 바꾼다.
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
from intent_v6_compressed_bench import (
    derive_flags,
    THRESHOLD_DOMINANT_TOP,
    THRESHOLD_DOMINANT_OTHERS,
    THRESHOLD_MULTI,
    MULTI_MIN_COUNT,
)


TODAY_FILES = [
    "IMG_2691.PNG",
    "IMG_2692.PNG",
    "IMG_2701.PNG",
    "IMG_2702.PNG",
    "IMG_2703.PNG",
    "IMG_2704.PNG",
    "IMG_2727.PNG",
    "IMG_2728.PNG",
    "IMG_2729.PNG",
]
RESULT_PATH = Path(__file__).parent / "intent_v6_compressed_today9_results.json"


def main() -> int:
    screenshots = [SCREENSHOT_DIR / n for n in TODAY_FILES]
    missing = [p for p in screenshots if not p.exists()]
    if missing:
        print(f"missing: {missing}", file=sys.stderr)
        return 1

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
        flags = derive_flags(cands)

        row = {
            "file": path.name,
            "bytes": len(data),
            "latency_ms": round(latency_ms, 1),
            "candidates": cands,
            "derived_flags": flags,
        }
        results.append(row)
        top_str = " | ".join(
            f"{c['label']}({c['applicability']:.2f},{c['intent']})" for c in cands
        )
        flag_labels = []
        if flags["dominant_single_intent"]:
            flag_labels.append("DOM")
        if flags["likely_multi_intent"]:
            flag_labels.append(f"MULTI×{flags['_n_above_multi_threshold']}")
        flag_str = ",".join(flag_labels) or "-"
        print(
            f"[{i}/{total}] {path.name} {len(data)//1024:>4}KB {latency_ms:>7.1f}ms [{flag_str}]\n"
            f"   {top_str}",
            file=sys.stderr,
        )

    latencies = [r["latency_ms"] for r in results]
    bytes_list = [r["bytes"] for r in results]
    summary = {
        "prompt_version": "v6",
        "preprocess": "fhd_jpeg_q60",
        "subset": "today9_2026-05-27",
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
        "thresholds": {
            "dominant_top": THRESHOLD_DOMINANT_TOP,
            "dominant_others_max": THRESHOLD_DOMINANT_OTHERS,
            "multi_min_applicability": THRESHOLD_MULTI,
            "multi_min_count": MULTI_MIN_COUNT,
        },
        "n_dominant": sum(1 for r in results if r["derived_flags"]["dominant_single_intent"]),
        "n_multi_intent": sum(1 for r in results if r["derived_flags"]["likely_multi_intent"]),
        "n_ambiguous_fallback": sum(
            1 for r in results
            if not r["derived_flags"]["dominant_single_intent"]
            and not r["derived_flags"]["likely_multi_intent"]
        ),
        "results": results,
    }
    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)
    print(json.dumps(summary["latency_ms"], indent=2), file=sys.stderr)
    print(
        f"\ndominant_single: {summary['n_dominant']}/{summary['n']}  "
        f"multi_intent: {summary['n_multi_intent']}/{summary['n']}  "
        f"ambiguous_fallback: {summary['n_ambiguous_fallback']}/{summary['n']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
