import { NextRequest } from "next/server";
import { analysisWireEvents, decodeFallbackId } from "@/lib/bff/fallback";
import { sseResponse } from "@/lib/bff/sse";

export const dynamic = "force-dynamic";

/* 분석 진행 SSE — 백엔드 GET /mochi_items/{id}/stream 대응. 본문은 final 후 재조회. */
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  if (decodeFallbackId(id)) {
    return sseResponse(analysisWireEvents(), { mode: "fallback" });
  }
  // P5: 라이브 id 는 실백엔드 스트림 프록시로
  return Response.json({ error: "unknown_item" }, { status: 404 });
}
