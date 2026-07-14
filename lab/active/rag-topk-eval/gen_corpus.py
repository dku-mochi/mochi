"""4V 코퍼스 생성 — Gemini flash-lite 배치 fan-out (asyncio 병렬 6).

config.QUERY_SPECS / FILLER_SPECS 를 배치 단위로 Gemini 에 보내 아이템을 생성하고,
Velocity(수집 창·최근 편중·재저장 근사중복)는 모델이 아니라 **코드가 결정적으로** 부여한다
(seed 고정 — 시간축 분포는 감사 가능해야 4V 의 V 다).

실행 (mochi-backend 디렉토리에서, ADC + GOOGLE_CLOUD_PROJECT):
  set -a; source .env; set +a
  uv run --group lab python ../lab/active/rag-topk-eval/gen_corpus.py [--only L01,F03]

출력: data/shards/<batch>.json  (재실행 시 이미 있는 샤드는 건너뜀 — --only 로 강제 재생성)
"""

import argparse
import asyncio
import json
import os
import sys
import zlib
from datetime import date, timedelta
from pathlib import Path

import numpy as np
from google import genai
from google.genai import types

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    DATE_MAX, DATE_MIN, FILLER_SPECS, GEN_MODEL, PERSONAS, QUERY_SPECS, SEED,
    STYLE_NOTE, TYPE_MIX_NOTE,
)

ROOT = Path(__file__).parent
SHARDS = ROOT / "data" / "shards"
CONCURRENCY = 6
D_MIN = date.fromisoformat(DATE_MIN)
D_MAX = date.fromisoformat(DATE_MAX)
SPAN_DAYS = (D_MAX - D_MIN).days

ITEM_SCHEMA_HINT = """각 아이템은 JSON 오브젝트:
{"type": "screenshot"|"link"|"memo",
 "summary": "한국어 1~2문장(45~140자). 모찌가 캡처를 분석해 남긴 요약 — 무엇이고 왜 저장했는지",
 "labels": ["짧은 저장 목적 1~2개 (예: 구매 고민, 가보고 싶은 곳)"],
 "entities": [{"kind":"brand|product|place|platform|date 등","value":"…"}] (0~3개),
 "occurs": "YYYY-MM-DD" 또는 null (내용상 마감/일정이 자연스러울 때만),
 "role": "answer"|"hard_neg"|"filler",
 "dup_of": null 또는 정수(이 배열에서 몇 번째(0-base) answer 를 다시 저장한 변형인지)}"""


def batch_prompt(spec: dict) -> str:
    persona = PERSONAS[spec["persona"]]
    if "query" in spec:
        dup_line = (
            "\n- 마지막에 1개: 위 answer 중 하나를 골라 며칠 뒤 '같은 대상을 다시 저장한' 변형"
            " 아이템(문구는 다르게, 대상은 동일)을 만들고 dup_of 에 그 answer 의 인덱스를 적어라."
            " role 은 answer." if spec["dup"] else ""
        )
        return f"""모찌(MOCHI)는 사용자가 하루 종일 스크린샷·링크·메모를 던져 넣는 기록 앱이다.
아래 페르소나가 실제로 저장했을 법한 기록 아이템들을 생성하라.

페르소나: {persona}
주제 도메인: {spec['domain']}
검색 쿼리(나중에 이 쿼리로 회수를 평가한다): "{spec['query']}"

생성할 것:
- answer {spec['n_answer']}개: 이 쿼리로 사용자가 되찾길 기대하는 기록. 쿼리 단어를 그대로 복사하지
  말고 실제 저장물처럼 구체적으로(상호명·브랜드·모델·장소명). 서로 다른 대상이어야 한다.
- hard_neg {spec['n_hard_neg']}개: {spec['hard_neg_note']} — 같은 토픽처럼 보이지만 이 쿼리의
  정답은 아닌 것. 의미 거리를 최대한 좁혀라(임베딩이 헷갈릴 만큼).{dup_line}

{TYPE_MIX_NOTE}. {STYLE_NOTE}.
{ITEM_SCHEMA_HINT}

JSON 배열만 출력하라."""
    return f"""모찌(MOCHI)는 사용자가 하루 종일 스크린샷·링크·메모를 던져 넣는 기록 앱이다.
아래 페르소나의 일상 기록(filler — 특정 검색 주제와 무관한 자연 노이즈) {spec['n']}개를 생성하라.

페르소나: {PERSONAS[spec['persona']]}
소재: {spec['domain']}
전부 role="filler", dup_of=null. 서로 소재가 겹치지 않게 넓게 흩어라.
{TYPE_MIX_NOTE}. {STYLE_NOTE}.
{ITEM_SCHEMA_HINT}

JSON 배열만 출력하라."""


def parse_items(text: str) -> list[dict]:
    t = text.strip()
    if t.startswith("```"):
        t = t.split("```")[1]
        t = t[4:] if t.startswith("json") else t
    return json.loads(t)


def validate(spec: dict, items: list[dict]) -> str | None:
    roles = [it.get("role") for it in items]
    if "query" in spec:
        n_ans = roles.count("answer")
        n_hn = roles.count("hard_neg")
        want_ans = spec["n_answer"] + (1 if spec["dup"] else 0)
        if n_ans != want_ans or n_hn != spec["n_hard_neg"]:
            return f"role 수 불일치: answer {n_ans}/{want_ans}, hard_neg {n_hn}/{spec['n_hard_neg']}"
        if spec["dup"]:
            dups = [it for it in items if it.get("dup_of") is not None]
            if len(dups) != 1:
                return f"dup_of 아이템 수 {len(dups)} != 1"
            src = dups[0]["dup_of"]
            answers = [i for i, it in enumerate(items) if it.get("role") == "answer" and it.get("dup_of") is None]
            if not isinstance(src, int) or src not in answers:
                return f"dup_of={src} 가 answer 인덱스가 아님"
    else:
        if len(items) != spec["n"] or roles.count("filler") != spec["n"]:
            return f"filler 수 불일치: {len(items)}/{spec['n']}"
    for it in items:
        if it.get("type") not in ("screenshot", "link", "memo"):
            return f"type 불량: {it.get('type')}"
        if not isinstance(it.get("summary"), str) or len(it["summary"]) < 20:
            return "summary 누락/과단"
        if not it.get("labels"):
            return "labels 누락"
    return None


def assign_velocity(spec: dict, items: list[dict], rng: np.random.RandomState) -> None:
    """수집 창 + 최근 편중 + dup 시차를 결정적으로 부여."""
    if "query" in spec:
        # 사람은 주제를 몇 주에 걸쳐 모은다 — 배치 수집 창(시작은 최근 편중, 폭 2~10주)
        back = min(int(rng.exponential(70)), SPAN_DAYS - 14)  # 창 '끝'이 얼마나 과거인가
        window_end = D_MAX - timedelta(days=back)
        width = int(rng.uniform(14, 70))
        window_start = max(D_MIN, window_end - timedelta(days=width))
        span = max((window_end - window_start).days, 1)
        for it in items:
            it["captured_at"] = (window_start + timedelta(days=int(rng.uniform(0, span)))).isoformat()
        # dup 는 원본보다 3~45일 뒤 (재저장의 현실 리듬)
        for it in items:
            if it.get("dup_of") is not None:
                src_date = date.fromisoformat(items[it["dup_of"]]["captured_at"])
                it["captured_at"] = min(D_MAX, src_date + timedelta(days=int(rng.uniform(3, 45)))).isoformat()
    else:
        # filler: 전역 지수 최근 편중 (절반 질량이 최근 ~45일)
        for it in items:
            back = min(int(rng.exponential(65)), SPAN_DAYS)
            it["captured_at"] = (D_MAX - timedelta(days=back)).isoformat()


def finalize(spec: dict, items: list[dict]) -> list[dict]:
    bid = spec.get("qid") or spec["bid"]
    out = []
    for i, it in enumerate(items):
        row = {
            "id": f"{bid.lower()}_{i:03d}",
            "type": it["type"],
            "summary": it["summary"].strip(),
            "labels": [str(x) for x in it["labels"]][:2],
            "entities": it.get("entities") or [],
            "category": spec["domain"],
            "persona": spec["persona"],
            "role": it["role"],
            "for_query": spec.get("query"),
            "tier": spec.get("tier"),
            "captured_at": it["captured_at"],
            "occurs": it.get("occurs"),
            "dup_of": (f"{bid.lower()}_{it['dup_of']:03d}" if it.get("dup_of") is not None else None),
        }
        out.append(row)
    return out


async def gen_batch(client: genai.Client, spec: dict, sem: asyncio.Semaphore) -> None:
    bid = spec.get("qid") or spec["bid"]
    path = SHARDS / f"{bid}.json"
    if path.exists():
        print(f"  [skip] {bid} (샤드 존재)")
        return
    async with sem:
        prompt = batch_prompt(spec)
        err_note = ""
        for attempt in (1, 2, 3):
            try:
                resp = await client.aio.models.generate_content(
                    model=GEN_MODEL,
                    contents=prompt + err_note,
                    config=types.GenerateContentConfig(
                        temperature=1.0,
                        response_mime_type="application/json",
                        max_output_tokens=8192,
                    ),
                )
                items = parse_items(resp.text)
                problem = validate(spec, items)
                if problem is None:
                    rng = np.random.RandomState(SEED + zlib.crc32(bid.encode()) % 10_000)
                    assign_velocity(spec, items, rng)
                    path.write_text(
                        json.dumps(finalize(spec, items), ensure_ascii=False, indent=1),
                        encoding="utf-8",
                    )
                    print(f"  [ok] {bid} ({len(items)} items, try {attempt})")
                    return
                err_note = f"\n\n[재시도 사유: 직전 출력이 스펙 위반 — {problem}. 스펙 수를 정확히 지켜라.]"
                print(f"  [retry {attempt}] {bid}: {problem}")
            except Exception as e:  # noqa: BLE001 — 배치 단위 재시도
                err_note = ""
                print(f"  [retry {attempt}] {bid}: {type(e).__name__} {e}")
                await asyncio.sleep(2 * attempt)
        print(f"  [FAIL] {bid} — 3회 실패, --only {bid} 로 재시도 필요")


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="쉼표구분 배치 id — 기존 샤드 삭제 후 재생성")
    args = ap.parse_args()

    SHARDS.mkdir(parents=True, exist_ok=True)
    specs = QUERY_SPECS + FILLER_SPECS
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        specs = [s for s in specs if (s.get("qid") or s["bid"]) in want]
        for s in specs:
            (SHARDS / f"{s.get('qid') or s['bid']}.json").unlink(missing_ok=True)

    client = genai.Client(
        vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location="global"
    )
    sem = asyncio.Semaphore(CONCURRENCY)
    print(f"[gen] {len(specs)} batches → {SHARDS} (model={GEN_MODEL})")
    await asyncio.gather(*(gen_batch(client, s, sem) for s in specs))
    n = len(list(SHARDS.glob("*.json")))
    print(f"[done] 샤드 {n}/{len(QUERY_SPECS) + len(FILLER_SPECS)}")


if __name__ == "__main__":
    asyncio.run(main())
