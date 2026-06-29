import { recallFeed } from "@/lib/api/backend";
import { serverEnv } from "@/lib/env";
import { RECALL_CARDS } from "@/seed/samples";
import type { IntentType, RecallCard, RecallReasonKind, TintKey } from "@/lib/types";

export const dynamic = "force-dynamic";

// ─────────────────────────────────────────────────────────────
// GET /api/recall — 회수(타임머신) 피드. 라이브 recallFeed()를 RecallCard[]
// 형태로 매핑해 JSON 반환. 실패/비활성 시 RECALL_CARDS 폴백.
// ─────────────────────────────────────────────────────────────

const TINTS: TintKey[] = ["purple", "blush", "mint", "butter", "sky", "peach"];
const VALID_INTENTS: IntentType[] = ["schedule", "todo", "knowledge", "memo"];
const VALID_REASONS: RecallReasonKind[] = ["deadline", "decay", "similarity"];

interface FeedRow {
  id?: string;
  itemId?: string;
  title?: string;
  summary?: string;
  oneline?: string;
  source?: string;
  imageUrl?: string;
  category?: string;
  intents?: string[];
  savedAt?: string;
  savedAtIso?: string;
  daysAgo?: number;
  reason?: { kind?: string; label?: string; detail?: string };
}

function mapRow(row: FeedRow, idx: number): RecallCard {
  const id = row.id ?? row.itemId ?? `recall-${idx}`;
  const intents = (row.intents ?? []).filter((i): i is IntentType =>
    VALID_INTENTS.includes(i as IntentType),
  );
  const reasonKind = VALID_REASONS.includes(row.reason?.kind as RecallReasonKind)
    ? (row.reason!.kind as RecallReasonKind)
    : "decay";
  return {
    id,
    kind: row.imageUrl ? "screenshot" : row.source ? "link" : "memo",
    title: row.title ?? "기록",
    oneline: row.oneline ?? row.summary ?? "",
    source: row.source,
    imageUrl: row.imageUrl,
    intents: intents.length ? intents : ["memo"],
    category: row.category,
    tint: TINTS[idx % TINTS.length],
    savedAtIso: row.savedAtIso ?? row.savedAt ?? new Date().toISOString(),
    daysAgo: typeof row.daysAgo === "number" ? row.daysAgo : 0,
    reason: {
      kind: reasonKind,
      label: row.reason?.label ?? "다시 볼 때",
      detail: row.reason?.detail ?? "",
    },
  };
}

export async function GET() {
  if (serverEnv.liveEnabled) {
    try {
      const res = await recallFeed();
      if (res.ok) {
        const data = await res.json();
        const rows: FeedRow[] = Array.isArray(data) ? data : (data?.items ?? data?.cards ?? []);
        if (Array.isArray(rows) && rows.length > 0) {
          return Response.json(rows.map(mapRow));
        }
      }
    } catch {
      /* 폴백으로 진행 */
    }
  }
  return Response.json(RECALL_CARDS);
}
