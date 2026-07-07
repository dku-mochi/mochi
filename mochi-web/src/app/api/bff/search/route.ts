import { NextRequest } from "next/server";
import { searchFallback } from "@/lib/bff/fallback";

export const dynamic = "force-dynamic";

/* 하이브리드 검색 — 백엔드 POST /search 응답 스키마와 동형. P4: 폴백. */
export async function POST(req: NextRequest) {
  let body: { query?: string; persona?: string };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  const query = (body.query ?? "").trim();
  if (!query) return Response.json({ error: "empty_query" }, { status: 422 });

  // 실검색의 체감 지연을 살짝 재현 (즉답이면 오히려 가짜처럼 보인다)
  await new Promise((r) => setTimeout(r, 550));

  const result = searchFallback(body.persona ?? "", query);
  return Response.json(result, { headers: { "x-mochi-mode": "fallback" } });
}
