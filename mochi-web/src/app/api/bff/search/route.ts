import { NextRequest } from "next/server";
import { searchFallback } from "@/lib/bff/fallback";
import { takeToken } from "@/lib/bff/ratelimit";
import { liveSearch, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/* 하이브리드 검색 — 백엔드 POST /search 응답 스키마와 동형. 라이브 우선, 실패 시 폴백 강등. */
export async function POST(req: NextRequest) {
  let body: { query?: string; persona?: string };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  // 512 = 백엔드 SearchRequest.query maxLength
  const query = (body.query ?? "").trim().slice(0, 512);
  const persona = body.persona ?? "";
  if (!query) return Response.json({ error: "empty_query" }, { status: 422 });

  const up = await prepareUpstream(persona);
  if (up && takeToken("search")) {
    const result = await liveSearch(up, query, req.signal);
    if (result) {
      return Response.json(result, { headers: { "x-mochi-mode": "live" } });
    }
  }

  // 실검색의 체감 지연을 살짝 재현 (즉답이면 오히려 가짜처럼 보인다)
  await new Promise((r) => setTimeout(r, 550));

  const result = searchFallback(persona, query);
  return Response.json(result, { headers: { "x-mochi-mode": "fallback" } });
}
