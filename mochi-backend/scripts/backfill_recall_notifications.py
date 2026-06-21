"""owner 의 기존 mochi_items 에 능동 회수 알림(트랙 A/B plan + C candidate)을 소급 생성하는 백필.

worker 분석 후단 hook(`_plan_recall_notifications` / `_generate_recall_candidates`)을 기존 데이터에
소급 적용한다 — prod 데이터를 로컬에 적재한 뒤 "알림이 어떻게 생성되고 홈 피드에 뜨는지" 확인용.
멱등: plan 은 active 1개(supersede)·candidate 는 recent_recall dedup 으로 재실행 안전.

트랙 C(candidate)는 시간순으로 돌려 "나중 저장이 이전 기억을 회수"가 자연스럽게 재현되게 한다.

실행 (mochi-backend, .env DATABASE_URL + Gemini ADC[트랙 A/B] 필요):
    PYTHONPATH=. uv run python scripts/backfill_recall_notifications.py --owner <UUID> \
        [--limit N] [--track-c-only] [--ab-only]
"""

import argparse
import asyncio
from uuid import UUID

from sqlalchemy import bindparam, text

from app.core.config import get_settings
from app.core.db import get_session_factory
from app.modules.mochi_items.application.queries import (
    GetMochiItemForOwner,
    make_mochi_item_repository,
)
from app.modules.notifications.application.get_recall_feed import GetRecallFeed
from app.modules.notifications.application.recall_planning_factory import (
    make_generate_recall_candidates,
    make_plan_recall_notifications,
)
from app.modules.notifications.infrastructure.recall_candidate_repository import (
    PostgresRecallCandidateRepository,
)
from app.modules.notifications.infrastructure.recall_feed_repository import (
    PostgresRecallFeedRepository,
)


async def _backfill(owner_id: UUID, limit: int | None, track_c_only: bool, ab_only: bool) -> None:
    sf = get_session_factory()
    async with sf() as s:
        rows = (
            await s.execute(
                text(
                    "SELECT id FROM mochi_items WHERE owner_id = :o AND deleted_at IS NULL "
                    "ORDER BY captured_at"
                ).bindparams(bindparam("o", owner_id))
            )
        ).all()
    ids = [r.id for r in rows]
    if limit:
        ids = ids[:limit]

    plans = 0
    cands = 0
    for i, mid in enumerate(ids, 1):
        async with sf() as s:
            item = await GetMochiItemForOwner(repository=make_mochi_item_repository(s)).execute(
                owner_id=owner_id, mochi_item_id=mid
            )
            if item is None:
                continue
            if not track_c_only:
                try:
                    plans += await make_plan_recall_notifications(s, owner_id=owner_id).run(
                        owner_id=owner_id,
                        mochi_item_id=mid,
                        intent_instances=item.intent_instances,
                    )
                except Exception as exc:  # noqa: BLE001 — 백필은 best-effort, 한 건 실패가 전체를 막지 않음
                    print(f"  [plan 실패] {mid}: {exc}")
            if not ab_only:
                try:
                    if await make_generate_recall_candidates(s).run(owner_id=owner_id, mochi_item_id=mid):
                        cands += 1
                except Exception as exc:  # noqa: BLE001
                    print(f"  [candidate 실패] {mid}: {exc}")
            await s.commit()
        if i % 20 == 0:
            print(f"  ...{i}/{len(ids)} 처리 (plans={plans}, candidates={cands})")

    print(f"\n=== 백필 완료: {len(ids)} items → plans={plans}, recall candidates={cands} ===")


async def _dump(owner_id: UUID) -> None:
    sf = get_session_factory()
    async with sf() as s:
        print("\n--- notification_plan (트랙 A/B 계획) ---")
        plan_rows = (
            await s.execute(
                text(
                    "SELECT plan_kind, status, stages->'stages'->0->'trigger'->>'type' AS trig, "
                    "stages->'stages'->0->>'content_template' AS tmpl "
                    "FROM notification_plan WHERE owner_id = :o ORDER BY created_at"
                ).bindparams(bindparam("o", owner_id))
            )
        ).all()
        for r in plan_rows:
            print(f"  [{r.plan_kind}/{r.status}] trigger={r.trig} :: {r.tmpl}")
        print(f"  총 {len(plan_rows)} plans")

        print("\n--- notification_outbox (실제 발송될 알림) ---")
        ob_rows = (
            await s.execute(
                text(
                    "SELECT kind, status, fire_at AT TIME ZONE 'Asia/Seoul' AS fire_kst, "
                    "title, body FROM notification_outbox WHERE owner_id = :o "
                    "ORDER BY fire_at"
                ).bindparams(bindparam("o", owner_id))
            )
        ).all()
        for r in ob_rows:
            print(f"  [{r.kind}/{r.status}] {r.fire_kst:%Y-%m-%d %H:%M} KST | {r.title} — {r.body}")
        print(f"  총 {len(ob_rows)} outbox rows")

    # 홈 피드(② 자세히 목록) — spaced(A) + recall(C) 합류
    async with sf() as s:
        feed = GetRecallFeed(
            feed=PostgresRecallFeedRepository(s),
            mochi_items=make_mochi_item_repository(s),
            candidates=PostgresRecallCandidateRepository(s),
        )
        entries = await feed.execute(owner_id=owner_id, limit=20)
    print("\n--- GET /recall/feed (홈 '한 칸' + 자세히 목록에 뜰 내용) ---")
    for e in entries:
        rel = f" +관련{len(e.related)}" if e.related else ""
        print(f"  [{e.kind}/{e.reason}]{rel} {e.title} — {e.oneline}")
    print(f"  총 {len(entries)} entries")


async def _run(owner: str, limit: int | None, track_c_only: bool, ab_only: bool, dump_only: bool) -> int:
    owner_id = UUID(owner)
    if not dump_only:
        await _backfill(owner_id, limit, track_c_only, ab_only)
    await _dump(owner_id)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", required=True, help="대상 owner UUID")
    parser.add_argument("--limit", type=int, default=None, help="처리할 item 수 상한")
    parser.add_argument("--track-c-only", action="store_true", help="트랙 C(candidate)만")
    parser.add_argument("--ab-only", action="store_true", help="트랙 A/B(plan)만")
    parser.add_argument("--dump-only", action="store_true", help="생성 없이 현재 상태만 출력")
    args = parser.parse_args()
    get_settings()
    return asyncio.run(_run(args.owner, args.limit, args.track_c_only, args.ab_only, args.dump_only))


if __name__ == "__main__":
    raise SystemExit(main())
