/*
 * 캡처 이미지 업로드 전처리 (브라우저 전용) — 긴 변 2000px 로 다운스케일해 JPEG 재인코딩.
 * 백엔드 분석(Gemini 비전)에 충분한 해상도를 유지하면서 업로드를 수 초 안으로 줄인다.
 * 이미 충분히 작은 JPEG/PNG 는 원본 그대로 통과 (텍스트 선명도 보존).
 */

const MAX_EDGE = 2000;
const PASSTHROUGH_BYTES = 1.5 * 1024 * 1024;
const PASSTHROUGH_MIME = new Set(["image/jpeg", "image/png"]);

export interface CaptureThumb {
  dataUrl: string;
  width: number;
  height: number;
}

// sessionStorage 오버레이에 들어가는 값 — 쿼터(~5MB)를 안전하게 밑돌게 상한
const THUMB_MAX_EDGE = 560;
const THUMB_MAX_DATAURL_CHARS = 400_000;

/**
 * 세션 오버레이용 소형 썸네일 (data URL) — 업로드본과 별개로, 이 브라우저의
 * 홈/보드 타일에 "내가 방금 보낸 그 이미지"를 그대로 보여주기 위한 것.
 * 실패(포맷·쿼터 초과)는 null — 오버레이는 이미지 없이도 성립한다.
 */
export async function captureThumb(source: Blob): Promise<CaptureThumb | null> {
  try {
    const bitmap = await createImageBitmap(source);
    try {
      const scale = Math.min(1, THUMB_MAX_EDGE / Math.max(bitmap.width, bitmap.height));
      const w = Math.max(1, Math.round(bitmap.width * scale));
      const h = Math.max(1, Math.round(bitmap.height * scale));
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext("2d");
      if (!ctx) return null;
      ctx.drawImage(bitmap, 0, 0, w, h);
      const dataUrl = canvas.toDataURL("image/jpeg", 0.72);
      if (dataUrl.length > THUMB_MAX_DATAURL_CHARS) return null;
      return { dataUrl, width: w, height: h };
    } finally {
      bitmap.close();
    }
  } catch {
    return null;
  }
}

export async function prepareCaptureImage(file: File): Promise<Blob> {
  if (PASSTHROUGH_MIME.has(file.type) && file.size <= PASSTHROUGH_BYTES) return file;

  const bitmap = await createImageBitmap(file);
  try {
    const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const w = Math.max(1, Math.round(bitmap.width * scale));
    const h = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("canvas_unavailable");
    ctx.drawImage(bitmap, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, "image/jpeg", 0.85),
    );
    if (!blob) throw new Error("encode_failed");
    return blob;
  } finally {
    bitmap.close();
  }
}
