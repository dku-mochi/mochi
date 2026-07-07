import { NextRequest } from "next/server";
import { encodeFallbackId, type IngestInput } from "@/lib/bff/fallback";

export const dynamic = "force-dynamic";

/*
 * 캡처 접수 — 백엔드 POST /mochi_items 대응. P4: 폴백 (입력을 id 에 인코딩해
 * 무상태로 분석을 재현). P5 에서 라이브 ingest + Idempotency-Key 가 앞단에 붙는다.
 */
export async function POST(req: NextRequest) {
  let body: IngestInput & { persona?: string };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  const input: IngestInput = {
    text: body.text?.slice(0, 600),
    url: body.url?.slice(0, 500),
    memo: body.memo?.slice(0, 300),
  };
  if (!input.text?.trim() && !input.url?.trim()) {
    return Response.json({ error: "empty_input" }, { status: 422 });
  }

  return Response.json(
    { id: encodeFallbackId(input) },
    { headers: { "x-mochi-mode": "fallback" } },
  );
}
