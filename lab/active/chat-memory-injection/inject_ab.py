"""채팅 메모리 주입 A/B/C 실험 — "기록에서 만든 프로필을 채팅에 주입하면 답이 '나처럼' 좋아지나".

배경: 모찌엔 이미 기록→프로필 distill 파이프라인이 있다(agent.RefreshUserProfile →
user_profiles 테이블). 하지만 채팅 system prompt(conversations)는 그 프로필을 읽지 않는다.
빠진 한 군데는 distill 이 아니라 "프로필 → 채팅 주입"이다. 이 실험은 그 주입의 효과만 격리 검증한다.

세 arm 을 같은 질문·같은 기록 컨텍스트로 비교한다 (검색 변수 제거 — 기록을 직접 컨텍스트로 제공):
  A0  프로필 없음           = 현재 모찌 채팅과 동일
  A1  기존(DB) 프로필 주입  = user_profiles.summary (분류 성향 위주)
  A2  채팅용 재-distill 주입 = "이 사람이 누구인지" 관심사·취향·맥락 중심 프로필

owner 는 기본적으로 가장 많이 쓴 사용자(=dev-jun)를 자동 선택. --email 로 변경 가능.

실행:
  GOOGLE_CLOUD_PROJECT=... uv run --directory mochi-backend \
    python ../lab/active/chat-memory-injection/inject_ab.py
  (옵션: --email dev-jun@dev.mochi.local --records 60)

출력: 콘솔에 질문별 3 arm 나란히 + results/<ts>.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path

from google import genai
from google.genai import types
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.core.config import get_settings

# 개인화가 답 품질을 가르는 질문들 — 단순 기록 나열로는 안 되고 "나에 대한 이해"가 필요한 것.
QUESTIONS = [
    "나 요즘 뭐에 관심 많은 것 같아?",
    "이번 주에 내가 챙겨야 할 거 있을까?",
    "주말에 나한테 어울릴 만한 거 하나 추천해줘.",
    "내가 자주 놓치는 것 위주로 리마인드해줄 게 있을까?",
    "요즘의 나를 한 문장으로 표현하면 어떤 사람일까?",
]

# 실제 채팅(conversations) 의 정체성·톤을 압축한 lab 전용 베이스. 실제 채팅은 tool 로 검색하지만
# 여기선 기록을 직접 컨텍스트로 주므로 검색 지시는 뺀다 — 프로필 효과만 깨끗이 보기 위함.
BASE_SYSTEM = (
    "너는 MOCHI(모찌) — 사용자의 두 번째 기억이야. 사용자는 하루 종일 스크린샷·링크·메모를 너에게 저장해 왔고, "
    "지금은 그 기억과 대화하는 중이야. 항상 한국어로, 따뜻하고 친근한 해요체로 답해. "
    "아래 [내 기록]에 근거해 답하되, 기록을 그대로 나열하지 말고 사용자를 이미 아는 친구처럼 자연스럽게 말해. "
    "기본 1~3문장. 모르면 솔직히 말해."
)

PROFILE_BLOCK = "\n\n[이 사용자에 대해 내가 아는 것]\n{profile}\n"

# A2: 채팅 비서 관점의 재-distill 프롬프트. 기존 프로필은 "어떻게 분류하나"(성향) 위주라,
# 채팅에선 "이 사람이 누구인지"(관심사·취향·맥락·반복 주제)가 더 중요하다는 가설을 검증.
REDISTILL_SYSTEM = (
    "너는 사용자를 깊이 이해하는 분석가야. 아래는 한 사용자가 저장해 온 기록들이야. "
    "이걸 바탕으로, 대화형 비서가 '이 사람처럼' 생각하기 위해 알아야 할 핵심을 5~7줄로 요약해줘. "
    "어떻게 분류하는지(memo/todo 같은 정리 습관)가 아니라, 이 사람이 누구인지에 집중해 — "
    "관심사·취향·요즘 몰두하는 것·생활 맥락·반복되는 주제·고민. 한국어로, 군더더기 없이."
)


def _fmt_records(rows: list[dict]) -> str:
    now = datetime.now(timezone.utc)
    lines = []
    for i, r in enumerate(rows, 1):
        captured = r["captured_at"]
        days = (now - captured).days if captured else None
        when = f"{days}일 전" if days is not None else "?"
        intents = "/".join(r["intents"] or []) or "-"
        body = (r["summary"] or "(분석 전)").strip()[:180]
        memo = f" | 메모: {r['user_memo']}" if r["user_memo"] else ""
        lines.append(f"{i}. [{when}][{intents}] {body}{memo}")
    return "\n".join(lines)


async def _load(engine, email: str | None, limit: int):
    async with engine.connect() as conn:
        if email:
            owner = (
                await conn.execute(
                    text("SELECT id, email FROM users WHERE email = :e"), {"e": email}
                )
            ).first()
        else:
            owner = (
                await conn.execute(
                    text(
                        "SELECT u.id, u.email FROM mochi_items mi JOIN users u ON u.id = mi.owner_id "
                        "WHERE mi.deleted_at IS NULL GROUP BY u.id, u.email "
                        "ORDER BY count(*) DESC LIMIT 1"
                    )
                )
            ).first()
        if owner is None:
            raise SystemExit(f"사용자를 찾지 못함: {email!r}")
        oid = owner.id

        rows = [
            dict(m)
            for m in (
                await conn.execute(
                    text(
                        "SELECT mi.summary, mi.user_memo, mi.captured_at, "
                        "  array_agg(DISTINCT ii.intent_type) "
                        "    FILTER (WHERE ii.intent_type IS NOT NULL) AS intents "
                        "FROM mochi_items mi "
                        "LEFT JOIN intent_instances ii ON ii.mochi_item_id = mi.id "
                        "WHERE mi.owner_id = :oid AND mi.deleted_at IS NULL "
                        "GROUP BY mi.id, mi.created_at ORDER BY mi.created_at DESC LIMIT :lim"
                    ),
                    {"oid": oid, "lim": limit},
                )
            ).mappings()
        ]

        stored = (
            await conn.execute(
                text("SELECT summary FROM user_profiles WHERE owner_id = :oid"), {"oid": oid}
            )
        ).scalar()

    return owner.email, rows, stored


async def _gen(client, model: str, system: str, user: str) -> str:
    cfg = types.GenerateContentConfig(
        system_instruction=system,
        temperature=0.6,
        max_output_tokens=2048,
        thinking_config=types.ThinkingConfig(thinking_budget=512),
    )
    resp = await client.aio.models.generate_content(model=model, contents=[user], config=cfg)
    return (resp.text or "").strip()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", default="dev-jun@dev.mochi.local")
    ap.add_argument("--records", type=int, default=60)
    args = ap.parse_args()

    s = get_settings()
    engine = create_async_engine(s.database_url)
    client = genai.Client(
        vertexai=True, project=s.google_cloud_project, location=s.gemini_agent_location
    )
    model = s.gemini_chat_model

    email, rows, stored_profile = await _load(engine, args.email, args.records)
    records_block = _fmt_records(rows)
    print(f"\n owner={email}  records={len(rows)}  model={model}")
    print(f" 기존 프로필(A1): {'있음' if stored_profile else '없음'}\n")

    # A2: 같은 기록으로 채팅용 프로필 재-distill (1회)
    redistilled = await _gen(client, model, REDISTILL_SYSTEM, f"[기록]\n{records_block}")
    print("=" * 80)
    print("[A2 재-distill 프로필]\n" + redistilled)
    print("=" * 80)

    arms = {
        "A0_no_profile": BASE_SYSTEM,
        "A1_stored": BASE_SYSTEM + (PROFILE_BLOCK.format(profile=stored_profile) if stored_profile else ""),
        "A2_redistilled": BASE_SYSTEM + PROFILE_BLOCK.format(profile=redistilled),
    }

    results = []
    for q in QUESTIONS:
        user = f"{q}\n\n[내 기록]\n{records_block}"
        print("\n" + "#" * 80 + f"\nQ: {q}\n" + "#" * 80)
        answers = {}
        for arm, system in arms.items():
            ans = await _gen(client, model, system, user)
            answers[arm] = ans
            print(f"\n── {arm} ──\n{ans}")
        results.append({"question": q, "answers": answers})

    out_dir = Path(__file__).parent / "results"
    out_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = out_dir / f"{ts}.json"
    out.write_text(
        json.dumps(
            {
                "owner": email,
                "model": model,
                "records": len(rows),
                "stored_profile": stored_profile,
                "redistilled_profile": redistilled,
                "results": results,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"\n\n저장: {out}")
    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
