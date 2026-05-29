#!/usr/bin/env python3
"""v6 prompt + fhd_jpeg_q60 + server-side flag 후처리.

v6 변경점 (codex consult 반영):
- 필드명: likelihood → applicability (LLM 출력은 확률이 아니라 적용 강도)
- boolean flag (dominant_single_intent / likely_multi_intent) 를 LLM 출력에서
  제거 → applicability 값으로 코드가 derive (일관성 ↑)
- prompt 안에 JSON 예시 명시 (강제력 ↑)
- "기록/참고" 규칙 자가 모순 정리 (정서적 박제 등 의도 자체가 일반어인
  케이스만 허용)

서버 후처리 규칙:
- dominant_single_intent = top.applicability >= 0.7 AND all others <= 0.3
- likely_multi_intent = count(c for c in cands if c.applicability >= 0.5) >= 2
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


RESULT_PATH = Path(__file__).parent / "intent_v6_compressed_results.json"

# Server-side thresholds (codex 권장 — boolean 은 LLM 이 아니라 코드가 결정)
THRESHOLD_DOMINANT_TOP = 0.7
THRESHOLD_DOMINANT_OTHERS = 0.3
THRESHOLD_MULTI = 0.5
MULTI_MIN_COUNT = 2


def derive_flags(candidates: list[dict]) -> dict:
    """LLM 출력의 applicability 값으로부터 분기 신호를 코드로 derive."""
    if not candidates:
        return {"dominant_single_intent": False, "likely_multi_intent": False}

    apps = sorted([c.get("applicability", 0.0) for c in candidates], reverse=True)
    top = apps[0]
    others = apps[1:]

    dominant = top >= THRESHOLD_DOMINANT_TOP and all(o <= THRESHOLD_DOMINANT_OTHERS for o in others)
    multi_count = sum(1 for a in apps if a >= THRESHOLD_MULTI)
    multi = multi_count >= MULTI_MIN_COUNT

    return {
        "dominant_single_intent": dominant,
        "likely_multi_intent": multi,
        "_n_above_multi_threshold": multi_count,
    }


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
