#!/usr/bin/env python3
"""이미지 전처리 (resize × compression) latency 영향 측정.

v3 prompt 그대로 사용하면서 입력 이미지의 (resize, format, quality) 만 변형하여
8장 × 5 variant = 40 호출. variant 별 latency / 전송 bytes / 분류 일관성 (top-1
intent 안정성) 을 비교한다.

variants:
  original     : 원본 PNG (현재 모찌가 보내는 형태)
  fhd_png      : max edge 1920px PNG (lossless resize)
  fhd_jpeg_q85 : max edge 1920px JPEG q=85 (moderate)
  fhd_jpeg_q60 : max edge 1920px JPEG q=60 (aggressive)
  hd_jpeg_q70  : max edge 1280px JPEG q=70 (aggressive + smaller)
"""

import argparse
import io
import json
import statistics
import sys
import time
from pathlib import Path

from PIL import Image
from google import genai
from google.genai import types

from intent_use_case_bench import (
    MODEL,
    SCREENSHOT_DIR,
    SYSTEM_PROMPT,
    RESPONSE_SCHEMA,
)


RESULT_PATH = Path(__file__).parent / "intent_preprocess_results.json"


def resize_and_compress(path: Path, max_edge: int | None, fmt: str, quality: int | None) -> tuple[bytes, str]:
    """이미지를 resize + compress 한 bytes 와 mime type 을 반환."""
    img = Image.open(path)
    if img.mode in ("RGBA", "P"):
        img = img.convert("RGB")

    if max_edge:
        w, h = img.size
        scale = min(max_edge / max(w, h), 1.0)
        if scale < 1.0:
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

    buf = io.BytesIO()
    save_kwargs = {}
    if fmt == "JPEG":
        save_kwargs["quality"] = quality
        save_kwargs["optimize"] = True
        mime = "image/jpeg"
    else:
        save_kwargs["optimize"] = True
        mime = "image/png"
    img.save(buf, format=fmt, **save_kwargs)
    return buf.getvalue(), mime


VARIANTS = [
    {"name": "original",     "max_edge": None, "fmt": None,   "quality": None},
    {"name": "fhd_png",      "max_edge": 1920, "fmt": "PNG",  "quality": None},
    {"name": "fhd_jpeg_q85", "max_edge": 1920, "fmt": "JPEG", "quality": 85},
    {"name": "fhd_jpeg_q60", "max_edge": 1920, "fmt": "JPEG", "quality": 60},
    {"name": "hd_jpeg_q70",  "max_edge": 1280, "fmt": "JPEG", "quality": 70},
]


def load_variant(path: Path, variant: dict) -> tuple[bytes, str]:
    if variant["fmt"] is None:
        return path.read_bytes(), "image/png"
    return resize_and_compress(path, variant["max_edge"], variant["fmt"], variant["quality"])


def classify(client: genai.Client, image_bytes: bytes, mime: str) -> tuple[float, dict]:
    cfg = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT,
        temperature=0.3,
        max_output_tokens=1024,
        response_mime_type="application/json",
        response_schema=RESPONSE_SCHEMA,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime)
    prompt = "이 스크린샷에 대한 use case 후보 3개를 생성하세요.\nJSON 만 응답.\n"

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
        parsed = {"candidates": [], "top_candidate_is_dominant": False, "_raw": resp.text}
    return latency_ms, parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=None)
    parser.add_argument("--location", default="global")
    args = parser.parse_args()

    screenshots = sorted(SCREENSHOT_DIR.glob("*.PNG")) + sorted(SCREENSHOT_DIR.glob("*.png"))
    client = genai.Client(vertexai=True, project=args.project, location=args.location)

    all_results: list[dict] = []

    for variant in VARIANTS:
        v_name = variant["name"]
        print(f"\n=== variant: {v_name} ===", file=sys.stderr)
        v_results = []
        for i, path in enumerate(screenshots, 1):
            data, mime = load_variant(path, variant)
            bytes_in = len(data)
            try:
                latency_ms, parsed = classify(client, data, mime)
                top = parsed["candidates"][0] if parsed.get("candidates") else {}
                row = {
                    "file": path.name,
                    "bytes": bytes_in,
                    "latency_ms": round(latency_ms, 1),
                    "top_label": top.get("label"),
                    "top_intent": top.get("intent"),
                    "top_likelihood": top.get("likelihood"),
                    "dominant": parsed.get("top_candidate_is_dominant"),
                }
            except Exception as e:
                row = {"file": path.name, "bytes": bytes_in, "error": str(e), "error_type": type(e).__name__}
            v_results.append(row)
            tag = f"{bytes_in//1024}KB"
            if "error" in row:
                print(f"  [{i}/{len(screenshots)}] {path.name} {tag} ERR {row['error_type']}", file=sys.stderr)
            else:
                print(
                    f"  [{i}/{len(screenshots)}] {path.name} {tag:>7}  "
                    f"{row['latency_ms']:>6.1f}ms  top={row['top_label']}/{row['top_intent']}",
                    file=sys.stderr,
                )

        latencies = [r["latency_ms"] for r in v_results if "latency_ms" in r]
        bytes_list = [r["bytes"] for r in v_results if "bytes" in r]
        summary = {
            "variant": v_name,
            "params": {k: variant[k] for k in ("max_edge", "fmt", "quality")},
            "n_ok": len(latencies),
            "latency_ms": {
                "min": round(min(latencies), 1) if latencies else None,
                "p50": round(statistics.median(latencies), 1) if latencies else None,
                "mean": round(statistics.mean(latencies), 1) if latencies else None,
                "max": round(max(latencies), 1) if latencies else None,
            },
            "bytes": {
                "min": min(bytes_list) if bytes_list else None,
                "mean": int(statistics.mean(bytes_list)) if bytes_list else None,
                "max": max(bytes_list) if bytes_list else None,
            },
            "rows": v_results,
        }
        all_results.append(summary)

    # 분류 일관성: 파일별로 variant 간 top_intent 분포
    intent_by_file: dict[str, list[tuple[str, str | None]]] = {}
    for v in all_results:
        for r in v["rows"]:
            intent_by_file.setdefault(r["file"], []).append((v["variant"], r.get("top_intent")))

    consistency = []
    for f, entries in intent_by_file.items():
        intents = [i for _, i in entries if i]
        unique = set(intents)
        consistency.append({
            "file": f,
            "intents_across_variants": dict(entries),
            "is_stable": len(unique) == 1,
        })

    output = {
        "model": MODEL,
        "n_screenshots": len(screenshots),
        "variants": all_results,
        "consistency": consistency,
    }
    RESULT_PATH.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)

    # 요약 표
    print("\n=== variant summary ===", file=sys.stderr)
    print(f"{'variant':<14} {'p50_ms':>8} {'mean_ms':>8} {'mean_KB':>8} {'stable':>7}", file=sys.stderr)
    stable_count = sum(1 for c in consistency if c["is_stable"])
    for v in all_results:
        v_stable = sum(
            1 for c in consistency
            if len({i for vn, i in c["intents_across_variants"].items() if vn == v["variant"]}) <= 1
        )
        print(
            f"{v['variant']:<14} {v['latency_ms']['p50']:>8.1f} {v['latency_ms']['mean']:>8.1f}"
            f" {v['bytes']['mean']//1024:>8} ",
            file=sys.stderr,
        )
    print(f"\nOverall intent stability across all variants: {stable_count}/{len(consistency)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
