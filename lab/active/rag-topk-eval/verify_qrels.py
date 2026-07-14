"""Veracity 2차 — 생성과 다른 모델(3.5-flash)의 qrels 전수 감사.

생성자(flash-lite)가 자기 라벨을 채점하지 않는다는 독립성 원칙:
쿼리별로 expected(answer) + hard_neg 후보를 셔플해 judge 에게 넘기고
"사용자가 이 쿼리로 자기 기록을 찾을 때 이 아이템이 반환되길 기대하는가"를 판정받는다.

적용 규칙(보수적 — 라벨 뒤집기는 로그로 남긴다):
  · expected 인데 judge=false → expected 에서 제거 (단, 그 쿼리 정답이 0 이 되면 유지+flag)
  · hard_neg 인데 judge=true  → expected 로 승격
출력: data/audit_report.json, data/gold_audited.json (run_eval 이 이걸 우선 사용)

실행: mochi-backend 에서  set -a; source .env; set +a
  uv run --group lab python ../lab/active/rag-topk-eval/verify_qrels.py
"""

import asyncio
import json
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
CONCURRENCY = 6

PROMPT = """모찌(MOCHI)는 개인 기록(스크린샷·링크·메모) 앱이다. 사용자가 검색창에 쿼리를 쳤다.
아래 각 후보 기록에 대해, **사용자가 이 쿼리로 자기 기록을 되찾으려 할 때 이 기록이 결과에
나오길 기대할 것인가**를 판정하라. 같은 토픽이라도 쿼리가 가리키는 대상·목적이 아니면 false 다
(예: 쿼리 '성수 카페'에 연남동 카페는 false). 반대로 표현이 달라도 대상이 맞으면 true 다.

쿼리: "{query}"

후보:
{candidates}

JSON 만 출력: {{"verdicts": [{{"id": "...", "relevant": true/false, "reason": "한 줄"}}]}}"""


async def judge_query(client, g, id2item, rng, sem):
    cands = [(i, "expected") for i in g["expected_ids"]] + [
        (it["id"], "hard_neg")
        for it in id2item.values()
        if it["role"] == "hard_neg" and it["for_query"] == g["query"]
    ]
    order = rng.permutation(len(cands))
    cands = [cands[i] for i in order]
    lines = []
    for cid, _ in cands:
        it = id2item[cid]
        lines.append(f'- id={cid} :: {it["summary"]} (라벨: {", ".join(it["labels"])})')
    async with sem:
        for attempt in (1, 2, 3):
            try:
                resp = await client.aio.models.generate_content(
                    model=JUDGE_MODEL,
                    contents=PROMPT.format(query=g["query"], candidates="\n".join(lines)),
                    config=types.GenerateContentConfig(
                        temperature=0.0, response_mime_type="application/json",
                        max_output_tokens=8192,
                    ),
                )
                verdicts = {v["id"]: v for v in json.loads(resp.text)["verdicts"]}
                if set(verdicts) >= {c for c, _ in cands}:
                    return g, dict(cands), verdicts
                print(f"  [retry {attempt}] {g['qid']}: verdict 누락")
            except Exception as e:  # noqa: BLE001
                print(f"  [retry {attempt}] {g['qid']}: {type(e).__name__}")
                await asyncio.sleep(2 * attempt)
    raise RuntimeError(f"{g['qid']} judge 3회 실패")


async def main() -> None:
    corpus = json.loads((DATA / "corpus.json").read_text(encoding="utf-8"))
    gold = json.loads((DATA / "gold.json").read_text(encoding="utf-8"))
    id2item = {it["id"]: it for it in corpus}
    client = genai.Client(
        vertexai=True, project=os.environ["GOOGLE_CLOUD_PROJECT"], location="global"
    )
    rng = np.random.RandomState(SEED)
    sem = asyncio.Semaphore(CONCURRENCY)
    results = await asyncio.gather(
        *(judge_query(client, g, id2item, rng, sem) for g in gold)
    )

    audited, report = [], []
    n_demote = n_promote = 0
    for g, roles, verdicts in results:
        exp = set(g["expected_ids"])
        fixes = []
        for cid, orig_role in roles.items():
            v = verdicts[cid]
            if orig_role == "expected" and not v["relevant"]:
                fixes.append({"id": cid, "fix": "demote", "reason": v["reason"]})
            elif orig_role == "hard_neg" and v["relevant"]:
                fixes.append({"id": cid, "fix": "promote", "reason": v["reason"]})
        new_exp = (exp - {f["id"] for f in fixes if f["fix"] == "demote"}) | {
            f["id"] for f in fixes if f["fix"] == "promote"
        }
        kept_all = False
        if not new_exp:  # 정답 전멸이면 원본 유지 + flag (judge 과공격 방어)
            new_exp, kept_all = exp, True
        n_demote += sum(1 for f in fixes if f["fix"] == "demote")
        n_promote += sum(1 for f in fixes if f["fix"] == "promote")
        audited.append({**g, "expected_ids": sorted(new_exp),
                        "single_answer": len(new_exp) == 1})
        report.append({"qid": g["qid"], "query": g["query"], "fixes": fixes,
                       "kept_all_despite_empty": kept_all,
                       "n_expected_before": len(exp), "n_expected_after": len(new_exp)})

    (DATA / "gold_audited.json").write_text(
        json.dumps(audited, ensure_ascii=False, indent=1), encoding="utf-8")
    corpus_sha = __import__("hashlib").sha256(
        (DATA / "corpus.json").read_bytes()).hexdigest()
    (DATA / "audit_meta.json").write_text(
        json.dumps({"corpus_sha256": corpus_sha}), encoding="utf-8")
    (DATA / "audit_report.json").write_text(
        json.dumps({"judge_model": JUDGE_MODEL, "n_demote": n_demote,
                    "n_promote": n_promote, "per_query": report},
                   ensure_ascii=False, indent=1), encoding="utf-8")
    total_before = sum(r["n_expected_before"] for r in report)
    print(f"감사 완료 — expected {total_before}개 중 demote {n_demote}, "
          f"hard_neg 승격 {n_promote} → gold_audited.json")
    for r in report:
        if r["fixes"]:
            print(f"  {r['qid']} {r['query']}: " + "; ".join(
                f"{f['fix']}:{f['id']}" for f in r["fixes"]))


if __name__ == "__main__":
    asyncio.run(main())
