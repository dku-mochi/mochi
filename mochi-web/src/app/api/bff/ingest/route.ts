import { NextRequest } from "next/server";
import { encodeFallbackId, type IngestInput } from "@/lib/bff/fallback";
import { takeToken } from "@/lib/bff/ratelimit";
import { liveIngest, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/*
 * 캡처 접수 — 백엔드 POST /mochi_items 대응. 라이브 우선(실 ingest + Idempotency-Key),
 * 실패 시 입력을 id 에 인코딩하는 무상태 폴백으로 강등.
 */
export async function POST(req: NextRequest) {
  let body: IngestInput & { persona?: string };
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  // 컴포저 maxLength(2000)와 동일값 — 여기서 더 자르면 사용자 모르게 내용이 유실된다
  const input: IngestInput = {
    text: body.text?.slice(0, 2000),
    url: body.url?.slice(0, 500),
    memo: body.memo?.slice(0, 500),
  };
  if (!input.text?.trim() && !input.url?.trim()) {
    return Response.json({ error: "empty_input" }, { status: 422 });
  }

  const persona = body.persona ?? "";
  const up = await prepareUpstream(persona);
  if (up && takeToken("ingest")) {
    const id = await liveIngest(up, persona, input);
    if (id) {
      return Response.json({ id }, { headers: { "x-mochi-mode": "live" } });
    }
  }

  return Response.json(
    { id: encodeFallbackId(input) },
    { headers: { "x-mochi-mode": "fallback" } },
  );
}
