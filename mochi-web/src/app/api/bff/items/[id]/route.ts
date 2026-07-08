import { NextRequest } from "next/server";
import { analyzeHeuristic, decodeFallbackId } from "@/lib/bff/fallback";
import { isLiveItemId, liveItem, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/* 분석 완료 아이템 조회 — 백엔드 GET /mochi_items/{id} 의 데모 표면 대응. */
export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const input = decodeFallbackId(id);
  if (input) {
    return Response.json(analyzeHeuristic(input), {
      headers: { "x-mochi-mode": "fallback" },
    });
  }
  if (isLiveItemId(id)) {
    const persona = req.nextUrl.searchParams.get("p") ?? "";
    const up = await prepareUpstream(persona);
    if (up) {
      const item = await liveItem(up, id, req.signal);
      if (item) {
        return Response.json(item, { headers: { "x-mochi-mode": "live" } });
      }
    }
  }
  return Response.json({ error: "unknown_item" }, { status: 404 });
}
