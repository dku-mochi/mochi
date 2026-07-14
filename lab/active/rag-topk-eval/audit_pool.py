"""codex P1-1 보정 — retrieval-pooled 무라벨 아이템 감사 + 순수 재채점.

문제: verify_qrels 는 해당 쿼리 배치(answer+hard_neg)만 감사한다. 실제 검색이 top-25 에
올린 filler/타배치 아이템이 진짜 정답이면 miss 로 채점돼 recall 이 왜곡된다(넓은 쿼리 취약).

처방: results/eval.json 의 저장 랭킹에서 A/B/C top-25 합집합 중 무라벨 아이템을 pooling →
독립 judge(3.5-flash)로 관련성 판정 → **API 재실행 없이** 저장 랭킹을 보정 라벨로 재채점.
동시에 재저장 dup 이중가중(codex P2)의 영향도 dup-그룹 채점 변형으로 정량화한다.

출력: results/eval_poolfix.json
실행: mochi-backend 에서  set -a; source .env; set +a
  uv run --group lab python ../lab/active/rag-topk-eval/audit_pool.py
"""

import asyncio
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
from google import genai
from google.genai import types

sys.path.insert(0, str(Path(__file__).parent))
from config import JUDGE_MODEL, SEED  # noqa: E402

ROOT = Path(__file__).parent
DATA = ROOT / "data"
RESULTS = ROOT / "results"
K_GRID = [8, 10, 15, 25]
CONCURRENCY = 6

PROMPT = """모찌(MOCHI)는 개인 기록(스크린샷·링크·메모) 앱이다. 사용자가 검색창에 쿼리를 쳤다.
아래 각 후보 기록에 대해, **사용자가 이 쿼리로 자기 기록을 되찾으려 할 때 이 기록이 결과에
나오길 기대할 것인가**를 판정하라. 같은 토픽이라도 쿼리가 가리키는 대상·목적이 아니면 false 다.

쿼리: "{query}"

후보:
{candidates}

JSON 만 출력: {{"verdicts": [{{"id": "...", "relevant": true/false}}]}}"""


async def judge_pool(client, pq, pool_ids, id2item, sem):
    if not pool_ids:
        return pq["qid"], []
    lines = [f'- id={i} :: {id2item[i]["summary"]} (라벨: {", ".join(id2item[i]["labels"])})'
             for i in pool_ids]
    async with sem:
        for attempt in (1, 2, 3):
            try:
                resp = await client.aio.models.generate_content(
                    model=JUDGE_MODEL,
                    contents=PROMPT.format(query=pq["query"], candidates="\n".join(lines)),
                    config=types.GenerateContentConfig(
                        temperature=0.0, response_mime_type="application/json",
                        max_output_tokens=8192,
                    ),
                )
                vs = json.loads(resp.text)["verdicts"]
                return pq["qid"], [v["id"] for v in vs if v.get("relevant") and v["id"] in pool_ids]
            except Exception as e:  # noqa: BLE001
                print(f"  [retry {attempt}] {pq['qid']}: {type(e).__name__}")
                await asyncio.sleep(2 * attempt)
    raise RuntimeError(f"{pq['qid']} pool judge 3회 실패")


def recall_at_k(ranked, expected, k):
    es = set(expected)
    return sum(1 for r in ranked[:k] if r in es) / len(es) if es else 0.0


def mrr25(ranked, expected):
    es = set(expected)
    for i, r in enumerate(ranked[:25], 1):
        if r in es:
            return 1.0 / i
    return 0.0


def group_recall_at_k(ranked, expected, k, root):
    groups = {root(e) for e in expected}
    hit = {root(r) for r in ranked[:k] if r in set(expected)}
    return len(hit) / len(groups) if groups else 0.0


def agg(rows, fn):
    return round(float(np.mean([fn(r) for r in rows])), 4) if rows else math.nan


async def main() -> None:
    ev = json.loads((RESULTS / "eval.json").read_text(encoding="utf-8"))
    corpus = json.loads((DATA / "corpus.json").read_text(encoding="utf-8"))
    id2item = {it["id"]: it for it in corpus}
    dup_root = {it["id"]: (it.get("dup_of") or it["id"]) for it in corpus}
    hard_by_q = {}
    for it in corpus:
        if it["role"] == "hard_neg":
            hard_by_q.setdefault(it["for_query"], set()).add(it["id"])

    client = genai.Client(
        vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location="global"
    )
    sem = asyncio.Semaphore(CONCURRENCY)
    per_query = ev["per_query"]
    pools = {}
    for pq in per_query:
        labeled = set(pq["expected_ids"]) | hard_by_q.get(pq["query"], set())
        union25 = []
        for pipe in ("A", "B", "C"):
            union25 += pq["pipelines"][pipe][:25]
        pools[pq["qid"]] = sorted({i for i in union25 if i not in labeled})

    results = await asyncio.gather(
        *(judge_pool(client, pq, pools[pq["qid"]], id2item, sem) for pq in per_query)
    )
    extra = dict(results)
    n_extra = sum(len(v) for v in extra.values())
    print(f"pool 감사: 무라벨 후보 {sum(len(p) for p in pools.values())}개 중 "
          f"추가 정답 판정 {n_extra}개 ({sum(1 for v in extra.values() if v)}개 쿼리)")

    variants = {
        "audited": lambda pq: pq["expected_ids"],
        "pool_corrected": lambda pq: sorted(set(pq["expected_ids"]) | set(extra[pq["qid"]])),
    }
    out = {"judge_model": JUDGE_MODEL, "seed": SEED,
           "pool_sizes": {q: len(p) for q, p in pools.items()},
           "extra_relevant": extra, "summary": {}}
    for vname, get_exp in variants.items():
        vsum = {}
        for pipe in ("A", "B", "C"):
            rows = [(pq, get_exp(pq)) for pq in per_query]
            vsum[pipe] = {
                "recall": {f"@{k}": round(float(np.mean(
                    [recall_at_k(pq["pipelines"][pipe], exp, k) for pq, exp in rows])), 4)
                    for k in K_GRID},
                "mrr@25": round(float(np.mean(
                    [mrr25(pq["pipelines"][pipe], exp) for pq, exp in rows])), 4),
                "by_tier": {t: {f"@{k}": round(float(np.mean(
                    [recall_at_k(pq["pipelines"][pipe], exp, k)
                     for pq, exp in rows if pq["tier"] == t])), 4) for k in K_GRID}
                    for t in ("S", "M", "L")},
            }
        out["summary"][vname] = vsum
    # dup-그룹 채점 (C, pool_corrected 라벨) — 재저장 이중가중 영향 정량화
    rows = [(pq, sorted(set(pq["expected_ids"]) | set(extra[pq["qid"]]))) for pq in per_query]
    out["summary"]["pool_corrected_dupgroup_C"] = {
        f"@{k}": round(float(np.mean(
            [group_recall_at_k(pq["pipelines"]["C"], exp, k, lambda i: dup_root[i])
             for pq, exp in rows])), 4) for k in K_GRID}

    (RESULTS / "eval_poolfix.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    for vname in ("audited", "pool_corrected"):
        c = out["summary"][vname]["C"]
        print(f"[{vname}] C recall {c['recall']}  L-tier {c['by_tier']['L']}")
    print("[dup-group C]", out["summary"]["pool_corrected_dupgroup_C"])
    print(f"저장: {RESULTS / 'eval_poolfix.json'}")


if __name__ == "__main__":
    asyncio.run(main())
