import { NextRequest } from "next/server";
import type { AnalyzedItemWire, ProposalType } from "@/lib/api/wire";
import { analyzeHeuristic, encodeFallbackId } from "@/lib/bff/fallback";
import {
  cancelLiveProposal,
  executeLiveProposal,
  isUuid,
  prepareUpstream,
} from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

const TYPES = new Set<ProposalType>([
  "item_update",
  "item_delete",
  "create_schedule",
  "reminder",
  "create_memo",
]);

function fallbackCreatedItem(
  proposalId: string,
  type: ProposalType,
  payload: Record<string, unknown>,
): AnalyzedItemWire | null {
  if (type === "create_memo") {
    const text = String(payload.text ?? payload.note ?? payload.title ?? "").trim();
    return text ? analyzeHeuristic({ text }) : null;
  }
  if (type !== "create_schedule") return null;
  const title = String(payload.title ?? "새 일정").trim();
  const date = String(payload.date ?? "").trim();
  const time = String(payload.time ?? "").trim();
  const note = String(payload.note ?? "").trim();
  const text = [title, date, time, note].filter(Boolean).join(" · ");
  return {
    id: encodeFallbackId({ text: `${proposalId}:${text}` }),
    title,
    summary: [date, time].filter(Boolean).length
      ? `${[date, time].filter(Boolean).join(" ")} 일정으로 체험에 반영했어요.`
      : "일정으로 체험에 반영했어요.",
    category: "일정",
    text,
    intents: [{ intentType: "schedule", label: title, date: date || undefined, time: time || undefined }],
  };
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ conversationId: string; proposalId: string }> },
) {
  const { conversationId, proposalId } = await params;
  let body: {
    action?: "confirm" | "cancel";
    persona?: string;
    type?: ProposalType;
    payload?: Record<string, unknown>;
  };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  const action = body.action ?? "confirm";
  const persona = body.persona ?? "";
  const type = body.type;
  const payload = body.payload ?? {};
  if (action === "confirm" && (!type || !TYPES.has(type))) {
    return Response.json({ error: "invalid_type" }, { status: 422 });
  }

  const liveIds = isUuid(conversationId) && isUuid(proposalId);
  const up = liveIds ? await prepareUpstream(persona) : null;
  if (action === "cancel") {
    if (up) await cancelLiveProposal(up, conversationId, proposalId);
    return Response.json({ status: "cancelled" });
  }

  if (type === "reminder") {
    return Response.json({ status: "preview" });
  }

  if (up && type) {
    const status = await executeLiveProposal(up, conversationId, proposalId);
    return Response.json({ status }, { headers: { "x-mochi-mode": "live" } });
  }

  const createdItem = type ? fallbackCreatedItem(proposalId, type, payload) : null;
  if (createdItem) {
    return Response.json(
      { status: "confirmed", createdItem },
      { headers: { "x-mochi-mode": "fallback" } },
    );
  }
  return Response.json({ status: "preview" }, { headers: { "x-mochi-mode": "fallback" } });
}
