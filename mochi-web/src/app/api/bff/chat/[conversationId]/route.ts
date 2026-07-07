import { NextRequest } from "next/server";
import { chatWireEvents } from "@/lib/bff/fallback";
import { sseResponse } from "@/lib/bff/sse";

export const dynamic = "force-dynamic";

/*
 * POST-as-SSE 채팅 — 백엔드 POST /conversations/{id}/messages 와 같은 wire.
 * P4: 폴백 재생. P5 에서 라이브 프록시 + 타임아웃 이어붙임이 앞단에 붙는다.
 */
export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ conversationId: string }> },
) {
  await params; // conversationId 는 클라 생성 — 폴백에서는 미사용
  let body: { text?: string; persona?: string };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  const text = (body.text ?? "").slice(0, 4000);
  const persona = body.persona ?? "";
  if (!text.trim()) {
    return Response.json({ error: "empty_text" }, { status: 422 });
  }

  return sseResponse(chatWireEvents(persona, text), { mode: "fallback" });
}
