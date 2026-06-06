"""추출 전략 벤치 — A(free-form) vs B(structured) vs C(hybrid) × flash-lite vs flash.

목적
----
채팅 기능을 위해 각 아이템에서 "무엇을 / 어떤 형태로" 추출해 DB 에 저장할지
결정한다. 현 프로덕션은 이미지를 LLM 에 넣지 않으므로
(`VertexAIGeminiClassifier` 만 back-tap 비전 경로) 여기서는 Gemini Vision 으로
이미지를, 그리고 텍스트 메모를 직접 추출하며 세 전략을 같은 데이터에 비교한다.

세 전략
-------
A. free-form : 종류 구분 없이 "정보 문장 리스트" 로 빠짐없이.
B. structured: facts / opinions / key_info / entities 로 미리 분류.
C. hybrid    : 문장마다 type(fact/opinion/info) 태그.

세 전략 공통(사용자가 짚은 포인트):
- intent 판단 + secondary_intents
- schedule 또는 마감 있는 todo → schedule_at (ISO, 없으면 생략)
- todo → reminder_kind: errand(미루는 심부름성) / goal(장기 목표성)

입력 두 종류
-----------
- image: lab/data/screenshot/*.png  (weak label = 파일명)
- text : lab/data/text_memos.json    (gold label = [구체적 의도, 4-intent], reminder_kind)
         텍스트는 gold label 이 있어 intent 분류 정확도까지 자동 측정한다.

실행
----
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
    uv run --directory mochi-backend \
    python lab/active/extraction-strategy/extraction_strategy_bench.py \
      [--mode image|text|both] [--smoke] [--limit N] [--concurrency K]

출력 (스크립트와 같은 폴더: lab/active/extraction-strategy/)
----
  extraction_strategy_results.json       / .._report.md        (image)
  extraction_strategy_text_results.json  / .._text_report.md   (text)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types

HERE = Path(__file__).parent           # lab/active/extraction-strategy/
LAB_ROOT = HERE.parent.parent          # lab/  (data/ 는 lab 공유 입력)
SHOT_DIR = LAB_ROOT / "data" / "screenshot"
TEXT_DATA = LAB_ROOT / "data" / "text_memos.json"
RESULTS_JSON = HERE / "extraction_strategy_results.json"
REPORT_MD = HERE / "extraction_strategy_report.md"
TEXT_RESULTS_JSON = HERE / "extraction_strategy_text_results.json"
TEXT_REPORT_MD = HERE / "extraction_strategy_text_report.md"

MODELS: dict[str, str] = {
    "flash-lite": "gemini-3.1-flash-lite",
    "flash": "gemini-3.5-flash",
}
LOCATION = "global"

# per 1M tokens, USD — ⚠️ ESTIMATE. 2026-05 공식 가격표로 검증 필요.
# flash-lite vs flash 의 "상대 비교" 용도로만 신뢰할 것.
PRICING: dict[str, dict[str, float]] = {
    "flash-lite": {"in": 0.10, "out": 0.40},
    "flash": {"in": 0.30, "out": 2.50},
}

_INTENT_ENUM = ["schedule", "todo", "knowledge", "memo"]

# --- 공통 시스템 프롬프트(베이스) -------------------------------------------

_BASE = """\
모찌(MOCHI)는 사용자가 나중에 다시 보려고 빠르게 남긴 스크린샷·링크·메모를
정리하는 기록 도구다.

지금 너의 일은 **"채팅"을 위한 추출**이다. 사용자는 나중에 이 기록을 두고
모찌와 대화한다 — "그때 그 마우스 모델명 뭐였지?", "이번 주에 가기로 한 행사
언제였지?", "내가 공부하려고 저장한 거 요점이 뭐였어?" 같은 질문에 모찌가
답하려면, 지금 이 기록에서 끌어낼 수 있는 정보를 충분히 추출해 두어야 한다.
요약 한 줄로는 부족하다. 나중에 대화에 쓰일 재료를 남긴다고 생각하라.

4-Intent 정의:
- schedule : 특정 시점에 발생/참여하는 사건 (약속, 마감일, 행사)
- todo     : 사용자가 직접 수행해야 할 행동 (구매, 답장, 신청, 시도)
- knowledge: 영구 참조 가치의 정보 (개념, 가이드, 학습 자료)
- memo     : 위 셋에 안 들어가는 정서적·일회적 기록 (영감, 추억, 자랑, 분위기)

공통 규칙:
- intent 를 먼저 판단하고, 동시에 해당하는 secondary_intents 도 적는다(없으면 빈 배열).
- schedule 이거나 마감이 있는 todo 면 schedule_at 에 날짜/시간을 ISO 8601 로 적는다.
  기록에 시점 단서가 없으면 schedule_at 을 비운다(추측 금지).
- intent 가 todo 면 reminder_kind 를 판단한다:
    "errand" = 지금 하긴 귀찮아 잠깐 미루는 심부름성 (예: 세제 사기, 답장하기)
    "goal"   = 기한이 길거나 없는 목표성 (예: 올해 토익 공부, 운동 시작)
  todo 가 아니면 reminder_kind 를 비운다.
- 기록에 실제로 있는 근거에서만 추출한다. 모르면 비운다. 사실을 지어내지 않는다.
- 모든 텍스트는 한국어로.
"""

_USER_PROMPT = "이 기록을 분석해 지정된 JSON 형식으로만 응답하라."

# --- 전략별 지시 + 응답 스키마 ----------------------------------------------

_COMMON_PROPS: dict[str, Any] = {
    "intent": {"type": "string", "enum": _INTENT_ENUM},
    "secondary_intents": {
        "type": "array",
        "items": {"type": "string", "enum": _INTENT_ENUM},
    },
    "schedule_at": {"type": "string", "nullable": True},
    "reminder_kind": {
        "type": "string",
        "enum": ["errand", "goal"],
        "nullable": True,
    },
}

_STRATEGY_INSTRUCTION: dict[str, str] = {
    "A": (
        "추출 방식 — 자유 문장형:\n"
        "이 기록에 대해 나중에 대화할 때 쓸 수 있는 정보를, 종류 구분 없이\n"
        "한국어 문장들의 리스트(statements)로 빠짐없이 추출하라. 객관적 사실,\n"
        "맥락, 사용자의 의도·감정·판단, 합리적 추론을 모두 한 리스트에 담는다.\n"
        "각 문장은 그 자체로 이해되는 완결된 정보 한 조각이어야 한다."
    ),
    "B": (
        "추출 방식 — 구조화:\n"
        "정보를 종류별로 분류해 추출하라.\n"
        "- facts    : 객관적·검증 가능한 사실 (제품명, 가격, 날짜, 수치, 고유명사)\n"
        "- opinions : 주관적 판단·감정·선호 (기록이나 사용자가 드러내는 태도)\n"
        "- key_info : facts/opinions 에 안 들어가지만 대화에 중요한 요점\n"
        "- entities : 핵심 개체 {kind, value} (kind 예: product, person, place, date, price, topic)"
    ),
    "C": (
        "추출 방식 — 하이브리드:\n"
        "정보를 한국어 문장(statements)으로 추출하되, 각 문장에 type 을 붙인다.\n"
        "- type=fact    : 객관적 사실\n"
        "- type=opinion : 주관적 판단·감정·선호\n"
        "- type=info    : 그 외 대화에 쓸 맥락·요점\n"
        "빠짐없이, 각 문장은 완결된 정보 한 조각."
    ),
}

_STRATEGY_SCHEMA: dict[str, dict[str, Any]] = {
    "A": {
        "type": "object",
        "properties": {
            **_COMMON_PROPS,
            "statements": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["intent", "statements"],
    },
    "B": {
        "type": "object",
        "properties": {
            **_COMMON_PROPS,
            "facts": {"type": "array", "items": {"type": "string"}},
            "opinions": {"type": "array", "items": {"type": "string"}},
            "key_info": {"type": "array", "items": {"type": "string"}},
            "entities": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "kind": {"type": "string"},
                        "value": {"type": "string"},
                    },
                    "required": ["kind", "value"],
                },
            },
        },
        "required": ["intent", "facts", "opinions", "key_info", "entities"],
    },
    "C": {
        "type": "object",
        "properties": {
            **_COMMON_PROPS,
            "statements": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string"},
                        "type": {
                            "type": "string",
                            "enum": ["fact", "opinion", "info"],
                        },
                    },
                    "required": ["text", "type"],
                },
            },
        },
        "required": ["intent", "statements"],
    },
}


def _system_for(strategy: str) -> str:
    return _BASE + "\n" + _STRATEGY_INSTRUCTION[strategy]


def _item_count(strategy: str, data: dict[str, Any]) -> int:
    """전략별 '추출 항목 수' — 전략 간 풍부함 비교의 1차 지표."""
    if strategy in ("A", "C"):
        return len(data.get("statements") or [])
    return (
        len(data.get("facts") or [])
        + len(data.get("opinions") or [])
        + len(data.get("key_info") or [])
        + len(data.get("entities") or [])
    )


# --- Gemini 호출 -------------------------------------------------------------

_local = threading.local()


def _client() -> genai.Client:
    """thread-local Gemini 클라이언트.

    google-genai 의 동기 Client 는 스레드 간 공유가 안전하지 않다
    (to_thread 풀에서 동시 사용 시 'client has been closed'). thread 당 1개로 격리.
    """
    c = getattr(_local, "client", None)
    if c is None:
        project = os.environ.get("GOOGLE_CLOUD_PROJECT")
        if not project:
            raise SystemExit(
                "GOOGLE_CLOUD_PROJECT 가 설정되지 않았습니다. "
                "예: GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 uv run python ..."
            )
        c = genai.Client(vertexai=True, project=project, location=LOCATION)
        _local.client = c
    return c


def _call_sync(*, model: str, part: types.Part, strategy: str) -> tuple[str, Any]:
    cfg = types.GenerateContentConfig(
        system_instruction=_system_for(strategy),
        temperature=0.3,
        max_output_tokens=2048,
        response_mime_type="application/json",
        response_schema=_STRATEGY_SCHEMA[strategy],
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    resp = _client().models.generate_content(
        model=model, contents=[part, _USER_PROMPT], config=cfg
    )
    return resp.text or "", getattr(resp, "usage_metadata", None)


@dataclass
class RunResult:
    sample: str  # 이미지 파일명 또는 메모 텍스트
    strategy: str
    model: str
    ok: bool
    latency_ms: float = 0.0
    tokens_in: int = 0
    tokens_out: int = 0
    cost_usd: float = 0.0
    item_count: int = 0
    intent: str | None = None
    secondary_intents: list[str] = field(default_factory=list)
    schedule_at: str | None = None
    reminder_kind: str | None = None
    data: dict[str, Any] | None = None
    error: str | None = None
    # text 모드 전용 gold label
    gold_intent: str | None = None
    gold_reminder_kind: str | None = None
    gold_desc: str | None = None  # 구체적 의도


async def _run_one(
    sem: asyncio.Semaphore,
    *,
    sample: str,
    part: types.Part,
    strategy: str,
    model_key: str,
    gold: dict[str, Any] | None = None,
) -> RunResult:
    model = MODELS[model_key]
    g_intent = gold.get("intent") if gold else None
    g_rk = gold.get("reminder_kind") if gold else None
    g_desc = gold.get("desc") if gold else None

    async with sem:
        t0 = time.perf_counter()
        try:
            raw, um = await asyncio.wait_for(
                asyncio.to_thread(_call_sync, model=model, part=part, strategy=strategy),
                timeout=60.0,
            )
            dt = (time.perf_counter() - t0) * 1000.0
        except Exception as exc:  # noqa: BLE001
            return RunResult(
                sample=sample, strategy=strategy, model=model_key, ok=False,
                latency_ms=(time.perf_counter() - t0) * 1000.0,
                error=f"{type(exc).__name__}: {str(exc)[:300]}",
                gold_intent=g_intent, gold_reminder_kind=g_rk, gold_desc=g_desc,
            )

    tok_in = int(getattr(um, "prompt_token_count", 0) or 0)
    tok_out = int(getattr(um, "candidates_token_count", 0) or 0)
    price = PRICING[model_key]
    cost = (tok_in * price["in"] + tok_out * price["out"]) / 1_000_000.0

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        return RunResult(
            sample=sample, strategy=strategy, model=model_key, ok=False,
            latency_ms=dt, tokens_in=tok_in, tokens_out=tok_out, cost_usd=cost,
            error=f"JSONDecodeError: {str(exc)[:200]} · raw[:200]={raw[:200]!r}",
            gold_intent=g_intent, gold_reminder_kind=g_rk, gold_desc=g_desc,
        )

    return RunResult(
        sample=sample, strategy=strategy, model=model_key, ok=True,
        latency_ms=dt, tokens_in=tok_in, tokens_out=tok_out, cost_usd=cost,
        item_count=_item_count(strategy, data),
        intent=data.get("intent"),
        secondary_intents=data.get("secondary_intents") or [],
        schedule_at=data.get("schedule_at"),
        reminder_kind=data.get("reminder_kind"),
        data=data,
        gold_intent=g_intent, gold_reminder_kind=g_rk, gold_desc=g_desc,
    )


async def _gather(tasks: list[Any], total: int, tag: str) -> list[RunResult]:
    results: list[RunResult] = []
    done = 0
    for coro in asyncio.as_completed(tasks):
        r = await coro
        done += 1
        flag = "✓" if r.ok else "✗"
        print(
            f"  [{tag} {done}/{total}] {flag} {r.model:<10} {r.strategy} "
            f"{r.sample[:28]:<28} items={r.item_count} {r.latency_ms:.0f}ms"
            + (f"  ERR {r.error[:70]}" if not r.ok else ""),
            flush=True,
        )
        results.append(r)
    return results


# --- 추출물 렌더 (공통) ------------------------------------------------------


def _fmt_extracted(strategy: str, data: dict[str, Any]) -> str:
    if not data:
        return "_(없음)_"
    lines: list[str] = []
    if strategy == "A":
        for s in data.get("statements") or []:
            lines.append(f"- {s}")
    elif strategy == "C":
        for s in data.get("statements") or []:
            lines.append(f"- `{s.get('type','?')}` {s.get('text','')}")
    else:  # B
        for key in ("facts", "opinions", "key_info"):
            vals = data.get(key) or []
            if vals:
                lines.append(f"- **{key}**")
                lines.extend(f"  - {v}" for v in vals)
        ents = data.get("entities") or []
        if ents:
            lines.append("- **entities**")
            lines.extend(f"  - `{e.get('kind','?')}` {e.get('value','')}" for e in ents)
    return "\n".join(lines) if lines else "_(빈 결과)_"


def _agg_table(results: list[RunResult], strategies: list[str], model_keys: list[str]) -> list[str]:
    out = [
        "| 모델 | 전략 | 평균 항목수 | 평균 tok_in | 평균 tok_out | 평균 비용($) | 평균 지연(ms) | 성공/전체 |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for mk in model_keys:
        for st in strategies:
            rs = [r for r in results if r.model == mk and r.strategy == st]
            ok = [r for r in rs if r.ok]
            n = len(rs)
            if not ok:
                out.append(f"| {mk} | {st} | - | - | - | - | - | 0/{n} |")
                continue
            avg = lambda f: sum(f(r) for r in ok) / len(ok)  # noqa: E731
            out.append(
                f"| {mk} | {st} | {avg(lambda r: r.item_count):.1f} "
                f"| {avg(lambda r: r.tokens_in):.0f} | {avg(lambda r: r.tokens_out):.0f} "
                f"| {avg(lambda r: r.cost_usd):.5f} | {avg(lambda r: r.latency_ms):.0f} "
                f"| {len(ok)}/{n} |"
            )
    return out


# --- 이미지 리포트 -----------------------------------------------------------


def _build_image_report(results: list[RunResult], samples: list[str]) -> str:
    by: dict[tuple[str, str, str], RunResult] = {
        (r.sample, r.model, r.strategy): r for r in results
    }
    strategies = ["A", "B", "C"]
    model_keys = sorted({r.model for r in results})

    out = ["# 추출 전략 비교 — 이미지 (A free-form / B structured / C hybrid)\n"]
    out.append(
        "> 같은 스크린샷을 세 전략 × 두 모델로 추출. 항목수·토큰·비용·지연은 자동 집계, "
        "품질(충실도/환각/유용성)은 사람이 아래 추출물로 판단.\n"
    )
    out.append("> ⚠️ 비용 단가는 추정치(코드 PRICING) — 모델 간 상대 비교용.\n")
    out.append("\n## 집계 (전략 × 모델 평균)\n")
    out += _agg_table(results, strategies, model_keys)

    out.append("\n## 이미지별 추출물 (나란히 비교)\n")
    for s in samples:
        out.append(f"\n### 📷 {s}\n")
        for mk in model_keys:
            out.append(f"\n#### 모델: {mk}\n")
            out.append("| 전략 | intent | secondary | schedule_at | reminder | 항목수 | tok_out | ms |")
            out.append("|---|---|---|---|---|---|---|---|")
            for st in strategies:
                r = by.get((s, mk, st))
                if r is None:
                    out.append(f"| {st} | _(미실행)_ | | | | | | |")
                elif not r.ok:
                    out.append(f"| {st} | ❌ {(r.error or 'err')[:36]} | | | | | | {r.latency_ms:.0f} |")
                else:
                    sec = ",".join(r.secondary_intents) or "-"
                    out.append(
                        f"| {st} | {r.intent} | {sec} | {r.schedule_at or '-'} "
                        f"| {r.reminder_kind or '-'} | {r.item_count} | {r.tokens_out} | {r.latency_ms:.0f} |"
                    )
            for st in strategies:
                r = by.get((s, mk, st))
                if r and r.ok:
                    out.append(f"\n**[{st}] 추출물**\n")
                    out.append(_fmt_extracted(st, r.data or {}))
                    out.append("")
    return "\n".join(out)


# --- 텍스트 리포트 (gold label 대비 정확도 포함) -----------------------------


def _build_text_report(results: list[RunResult], samples: list[str]) -> str:
    by: dict[tuple[str, str, str], RunResult] = {
        (r.sample, r.model, r.strategy): r for r in results
    }
    strategies = ["A", "B", "C"]
    model_keys = sorted({r.model for r in results})

    out = ["# 추출 전략 비교 — 텍스트 메모 (gold label 대비)\n"]
    out.append(
        "> 짧고 추상적인 메모를 세 전략 × 두 모델로 추출. gold label([구체적 의도, intent], "
        "reminder_kind)이 있어 intent 분류 정확도까지 자동 측정.\n"
    )
    out.append("> ⚠️ 비용 단가는 추정치(코드 PRICING) — 모델 간 상대 비교용.\n")

    out.append("\n## 집계 — 풍부함·비용\n")
    out += _agg_table(results, strategies, model_keys)

    out.append("\n## 집계 — gold 대비 정확도\n")
    out.append("| 모델 | 전략 | intent 정확도 | reminder 정확도(todo) |")
    out.append("|---|---|---|---|")
    for mk in model_keys:
        for st in strategies:
            ok = [r for r in results if r.model == mk and r.strategy == st and r.ok]
            if not ok:
                out.append(f"| {mk} | {st} | - | - |")
                continue
            hit = sum(1 for r in ok if r.intent == r.gold_intent)
            todo = [r for r in ok if r.gold_intent == "todo"]
            rk_hit = sum(1 for r in todo if (r.reminder_kind or None) == (r.gold_reminder_kind or None))
            rk = f"{rk_hit}/{len(todo)}" if todo else "-"
            out.append(f"| {mk} | {st} | {hit}/{len(ok)} ({hit/len(ok)*100:.0f}%) | {rk} |")

    out.append("\n## 메모별 추출물 (나란히 비교)\n")
    for s in samples:
        gold = next((r for r in results if r.sample == s and r.gold_intent), None)
        glabel = f"[{gold.gold_desc}, {gold.gold_intent}]" if gold else "?"
        grk = f" · reminder={gold.gold_reminder_kind}" if (gold and gold.gold_reminder_kind) else ""
        out.append(f"\n### 📝 “{s}”  — gold {glabel}{grk}\n")
        for mk in model_keys:
            out.append(f"\n#### 모델: {mk}\n")
            out.append("| 전략 | pred intent | 정답? | schedule_at | reminder | 항목수 | tok_out | ms |")
            out.append("|---|---|---|---|---|---|---|---|")
            for st in strategies:
                r = by.get((s, mk, st))
                if r is None:
                    out.append(f"| {st} | _(미실행)_ | | | | | | |")
                elif not r.ok:
                    out.append(f"| {st} | ❌ {(r.error or 'err')[:30]} | | | | | | {r.latency_ms:.0f} |")
                else:
                    mark = "✅" if r.intent == r.gold_intent else "❌"
                    out.append(
                        f"| {st} | {r.intent} | {mark} | {r.schedule_at or '-'} "
                        f"| {r.reminder_kind or '-'} | {r.item_count} | {r.tokens_out} | {r.latency_ms:.0f} |"
                    )
            for st in strategies:
                r = by.get((s, mk, st))
                if r and r.ok:
                    out.append(f"\n**[{st}] 추출물**\n")
                    out.append(_fmt_extracted(st, r.data or {}))
                    out.append("")
    return "\n".join(out)


# --- 벤치 실행 ---------------------------------------------------------------


async def _image_bench(sem: asyncio.Semaphore, args: argparse.Namespace) -> None:
    if not SHOT_DIR.exists():
        print(f"[image] 스크린샷 디렉토리 없음: {SHOT_DIR} — 스킵")
        return
    images = sorted({p for p in SHOT_DIR.iterdir() if p.suffix.lower() == ".png"})
    if not images:
        print(f"[image] PNG 없음: {SHOT_DIR} — 스킵")
        return

    strategies = ["A", "B", "C"]
    model_keys = list(MODELS.keys())
    if args.smoke:
        images, model_keys = images[:1], ["flash-lite"]
    elif args.limit > 0:
        images = images[: args.limit]

    total = len(images) * len(strategies) * len(model_keys)
    print(f"[image] 이미지 {len(images)} × 전략 {len(strategies)} × 모델 {len(model_keys)} = {total} 호출", flush=True)

    parts = {p: types.Part.from_bytes(data=p.read_bytes(), mime_type="image/png") for p in images}
    tasks = [
        _run_one(sem, sample=p.name, part=parts[p], strategy=st, model_key=mk)
        for p in images for mk in model_keys for st in strategies
    ]
    results = await _gather(tasks, total, "image")

    order = {p.name: i for i, p in enumerate(images)}
    results.sort(key=lambda r: (order.get(r.sample, 999), r.model, r.strategy))
    RESULTS_JSON.write_text(
        json.dumps(
            {"meta": {"models": MODELS, "pricing_estimate": PRICING, "n": len(images)},
             "runs": [asdict(r) for r in results]},
            ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    REPORT_MD.write_text(_build_image_report(results, [p.name for p in images]), encoding="utf-8")
    ok = sum(1 for r in results if r.ok)
    print(f"[image] 완료 {ok}/{len(results)} · {RESULTS_JSON.name} / {REPORT_MD.name}")


async def _text_bench(sem: asyncio.Semaphore, args: argparse.Namespace) -> None:
    if not TEXT_DATA.exists():
        print(f"[text] 데이터셋 없음: {TEXT_DATA} — 스킵 (서브에이전트 생성 대기)")
        return
    ds = json.loads(TEXT_DATA.read_text(encoding="utf-8"))
    items = ds.get("items", [])
    if not items:
        print(f"[text] 항목 없음: {TEXT_DATA} — 스킵")
        return

    strategies = ["A", "B", "C"]
    model_keys = list(MODELS.keys())
    if args.smoke:
        items, model_keys = items[:1], ["flash-lite"]
    elif args.limit > 0:
        items = items[: args.limit]

    total = len(items) * len(strategies) * len(model_keys)
    print(f"[text] 메모 {len(items)} × 전략 {len(strategies)} × 모델 {len(model_keys)} = {total} 호출", flush=True)

    tasks = []
    for it in items:
        memo = it["memo"]
        label = it.get("label") or []
        gold = {
            "intent": label[1] if len(label) > 1 else None,
            "desc": label[0] if label else None,
            "reminder_kind": it.get("reminder_kind"),
        }
        part = types.Part(text=memo)
        for mk in model_keys:
            for st in strategies:
                tasks.append(
                    _run_one(sem, sample=memo, part=part, strategy=st, model_key=mk, gold=gold)
                )
    results = await _gather(tasks, total, "text")

    order = {it["memo"]: i for i, it in enumerate(items)}
    results.sort(key=lambda r: (order.get(r.sample, 999), r.model, r.strategy))
    TEXT_RESULTS_JSON.write_text(
        json.dumps(
            {"meta": {"models": MODELS, "pricing_estimate": PRICING, "n": len(items)},
             "runs": [asdict(r) for r in results]},
            ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    TEXT_REPORT_MD.write_text(_build_text_report(results, [it["memo"] for it in items]), encoding="utf-8")
    ok = sum(1 for r in results if r.ok)
    print(f"[text] 완료 {ok}/{len(results)} · {TEXT_RESULTS_JSON.name} / {TEXT_REPORT_MD.name}")


async def _main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["image", "text", "both"], default="image")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args()

    sem = asyncio.Semaphore(args.concurrency)
    if args.mode in ("image", "both"):
        await _image_bench(sem, args)
    if args.mode in ("text", "both"):
        await _text_bench(sem, args)


if __name__ == "__main__":
    asyncio.run(_main())
