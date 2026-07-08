"""기존 mochi_items 를 voyage-4-large@1024 로 (재)색인하는 배치.

대상: ``deleted_at IS NULL`` 이고, 임베딩 행이 없거나 ``model_version`` 이 현재 설정과
다른 아이템. 멱등 — 이미 현재 모델로 색인된 아이템은 건너뛰므로 재실행이 안전하다.
INDEXED 노드의 best-effort 실패분(voyage 일시 장애 등) 복구 경로이기도 하다.

임베딩 input 은 ingestion 과 동일하게 ``build_embedding_text``(summary + intent labels) —
색인 시점이 달라도 문서 표현이 갈라지면 안 된다.

실행 (mochi-backend 디렉토리, .env 에 VOYAGE_API_KEY·DATABASE_URL):
    PYTHONPATH=. uv run python scripts/backfill_embeddings.py [--batch 64] [--dry-run]
"""

import argparse
import asyncio
import sys
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import bindparam, text

from app.core.config import get_settings
from app.core.db import get_session_factory
from app.core.deps import get_voyage_client
from app.shared.voyage import build_embedding_text

_SELECT_PENDING = text(
    """
    SELECT m.id, m.owner_id, m.summary,
           (SELECT coalesce(array_agg(ii.label), ARRAY[]::varchar[])
            FROM intent_instances ii
            WHERE ii.mochi_item_id = m.id AND ii.label IS NOT NULL) AS labels
    FROM mochi_items m
    WHERE m.deleted_at IS NULL
      -- ingestion(build_embedding_text)과 동일 커버리지: summary 또는 label 이 있으면 색인
      -- 대상 (summary 단독 필터는 label-only 아이템을 영구 제외 — 리뷰 P2).
      AND (m.summary IS NOT NULL AND m.summary != ''
           OR EXISTS (SELECT 1 FROM intent_instances ii2
                      WHERE ii2.mochi_item_id = m.id AND ii2.label IS NOT NULL AND ii2.label != ''))
      AND NOT EXISTS (SELECT 1 FROM embeddings e
                      WHERE e.mochi_item_id = m.id AND e.model_version = :model_version)
    ORDER BY m.captured_at
    LIMIT :batch
    """
)

_DELETE_OLD = text("DELETE FROM embeddings WHERE mochi_item_id = ANY(:ids)")

_INSERT = text(
    """
    INSERT INTO embeddings (mochi_item_id, chunk_text, embedding, model_version)
    VALUES (:mochi_item_id, :chunk_text, CAST(:embedding AS vector), :model_version)
    """
)


@dataclass(slots=True)
class _Pending:
    mochi_item_id: UUID
    chunk_text: str


async def _run(batch_size: int, dry_run: bool) -> int:
    client = get_voyage_client()
    if client is None:
        print("VOYAGE_API_KEY 가 설정되지 않았습니다 — .env 를 확인하세요.", file=sys.stderr)
        return 1
    model_version = client.model_version
    session_factory = get_session_factory()
    total = 0

    while True:
        async with session_factory() as session:
            rows = (
                await session.execute(
                    _SELECT_PENDING.bindparams(
                        bindparam("model_version", model_version),
                        bindparam("batch", batch_size),
                    )
                )
            ).all()
            pending = [
                _Pending(mochi_item_id=row.id, chunk_text=chunk)
                for row in rows
                if (chunk := build_embedding_text(row.summary, list(row.labels or [])))
            ]
            # 색인할 텍스트가 비는 행(summary·label 전무)은 영원히 후보로 남으므로 집계만 알린다.
            skipped = len(rows) - len(pending)
            if not rows:
                break
            if dry_run:
                for item in pending:
                    print(f"[dry-run] {item.mochi_item_id}: {item.chunk_text[:80]!r}")
                total += len(pending)
                if len(rows) < batch_size:
                    break
                print("[dry-run] 첫 배치만 표시하고 종료합니다 (멱등 마킹이 없어 무한루프 방지).")
                break
            if not pending:
                print(f"색인 가능한 텍스트가 없는 행 {skipped}건 — 종료.", file=sys.stderr)
                break

            vectors = await client.embed_documents([item.chunk_text for item in pending])
            ids = [item.mochi_item_id for item in pending]
            await session.execute(_DELETE_OLD.bindparams(bindparam("ids", ids)))
            for item, vector in zip(pending, vectors, strict=True):
                await session.execute(
                    _INSERT.bindparams(
                        bindparam("mochi_item_id", item.mochi_item_id),
                        bindparam("chunk_text", item.chunk_text),
                        bindparam("embedding", "[" + ",".join(map(str, vector)) + "]"),
                        bindparam("model_version", model_version),
                    )
                )
            await session.commit()
            total += len(pending)
            print(f"색인 {total}건 (+{len(pending)}, 텍스트 없음 {skipped}건 건너뜀)")
            if skipped and len(rows) < batch_size:
                break

    print(f"완료 — 총 {total}건 색인 ({model_version}).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", type=int, default=64, help="배치 크기 (기본 64)")
    parser.add_argument("--dry-run", action="store_true", help="색인 없이 대상만 출력")
    args = parser.parse_args()
    get_settings()  # .env 로드 fail-fast
    return asyncio.run(_run(args.batch, args.dry_run))


if __name__ == "__main__":
    raise SystemExit(main())
