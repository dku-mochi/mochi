import { SAMPLE_CARDS } from "@/seed/samples";

export const dynamic = "force-dynamic";

// ─────────────────────────────────────────────────────────────
// GET /api/samples — 갤러리 카드. 라이브 listItems()는 형태 매핑이 크니
// 지금은 SAMPLE_CARDS(실DB 추출 5건)를 그대로 반환한다.
// ─────────────────────────────────────────────────────────────

export async function GET() {
  return Response.json(SAMPLE_CARDS);
}
