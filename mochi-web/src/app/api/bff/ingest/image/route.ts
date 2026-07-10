import { NextRequest } from "next/server";
import { encodeFallbackId } from "@/lib/bff/fallback";
import { takeToken } from "@/lib/bff/ratelimit";
import { liveImageIngest, prepareUpstream } from "@/lib/bff/upstream";

export const dynamic = "force-dynamic";

/*
 * 이미지 캡처 접수 — 백엔드 presign → GCS PUT → imageRefs ingest 3단을 서버가 대행.
 * 브라우저는 multipart 한 번이면 되고(버킷 CORS 불필요), 이후 진행 SSE·본문 재조회는
 * 텍스트 ingest 와 같은 경로를 탄다. 라이브 불가 시 이미지는 폴백이 볼 수 없으므로
 * 메모 텍스트 폴백으로 강등해 여정을 완결한다.
 */

// 클라가 긴 변 2000px JPEG 로 다운스케일해 보낸다 — 그 기준의 여유 상한
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
// 백엔드 _CAPTURE_ALLOWED_MIME 과 동일
const ALLOWED_MIME = new Set(["image/jpeg", "image/png"]);

export async function POST(req: NextRequest) {
  // formData() 는 body 전체를 버퍼링 — 파싱 전에 신고된 크기부터 자른다 (multipart 오버헤드 여유분 포함)
  const declared = Number(req.headers.get("content-length") ?? 0);
  if (declared > MAX_IMAGE_BYTES + 64 * 1024) {
    return Response.json({ error: "too_large" }, { status: 413 });
  }
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return Response.json({ error: "invalid_body" }, { status: 400 });
  }
  const file = form.get("image");
  const personaRaw = form.get("persona");
  const memoRaw = form.get("memo");
  const persona = typeof personaRaw === "string" ? personaRaw : "";
  const memo = typeof memoRaw === "string" ? memoRaw.slice(0, 500) : undefined;

  if (!(file instanceof Blob) || file.size === 0) {
    return Response.json({ error: "empty_image" }, { status: 422 });
  }
  if (!ALLOWED_MIME.has(file.type) || file.size > MAX_IMAGE_BYTES) {
    return Response.json({ error: "unsupported_image" }, { status: 422 });
  }

  const up = await prepareUpstream(persona);
  if (up && takeToken("ingest")) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const id = await liveImageIngest(up, persona, { bytes, mimeType: file.type, memo });
    if (id) {
      return Response.json({ id }, { headers: { "x-mochi-mode": "live" } });
    }
  }

  return Response.json(
    { id: encodeFallbackId({ text: memo?.trim() || "방금 보낸 스크린샷", memo }) },
    { headers: { "x-mochi-mode": "fallback" } },
  );
}
