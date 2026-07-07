import { NextRequest } from "next/server";
import { analysisWireEvents, decodeFallbackId } from "@/lib/bff/fallback";
import { sseResponse } from "@/lib/bff/sse";
import { isLiveItemId, openLiveAnalysis, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/*
 * 분석 진행 SSE — 백엔드 GET /mochi_items/{id}/stream 대응. 본문은 final 후 재조회.
 * 라이브 id(uuid)는 프록시(절단 시 final 이어붙임), fb. id 는 폴백 재생.
 */
export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  if (decodeFallbackId(id)) {
    return sseResponse(analysisWireEvents(), { mode: "fallback", signal: req.signal });
  }
  if (isLiveItemId(id)) {
    const persona = req.nextUrl.searchParams.get("p") ?? "";
    const up = await prepareUpstream(persona);
    if (up) {
      const live = await openLiveAnalysis({ ...up, itemId: id, signal: req.signal });
      if (live) return sseResponse(live, { mode: "live", signal: req.signal });
    }
    // upstream 이 닫힌 극단(킬스위치·개시 실패) — 진행 연출만 폴백으로 완결
    return sseResponse(analysisWireEvents(), { mode: "fallback", signal: req.signal });
  }
  return Response.json({ error: "unknown_item" }, { status: 404 });
}
