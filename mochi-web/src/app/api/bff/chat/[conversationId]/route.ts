import { NextRequest } from "next/server";
import { chatWireEvents } from "@/lib/bff/fallback";
import { takeToken } from "@/lib/bff/ratelimit";
import { sseResponse } from "@/lib/bff/sse";
import { isUuid, openLiveChat, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/*
 * POST-as-SSE 채팅 — 백엔드 POST /conversations/{id}/messages 와 같은 wire.
 * 라이브 우선, 실패·타임아웃은 서버가 폴백 이벤트를 이어붙여 완결 (클라는 모드를 모른다).
 */
export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ conversationId: string }> },
) {
  const { conversationId } = await params;
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

  // uuid allowlist — 클라 입력이 upstream URL path 에 실리므로 경로 주입 차단
  const up = isUuid(conversationId) ? await prepareUpstream(persona) : null;
  if (up && takeToken("chat")) {
    const live = await openLiveChat({
      ...up,
      conversationId,
      personaSlug: persona,
      text,
      signal: req.signal,
    });
    if (live) return sseResponse(live, { mode: "live", signal: req.signal });
  }
  return sseResponse(chatWireEvents(persona, text), { mode: "fallback", signal: req.signal });
}
