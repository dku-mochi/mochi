import "server-only";

// ─────────────────────────────────────────────────────────────
// 인메모리 슬라이딩 윈도 rate-limit. Vercel 인스턴스별 메모리라 완벽하진
// 않지만(서버리스 콜드스타트/멀티 인스턴스마다 별도 Map) 데모엔 충분.
// ─────────────────────────────────────────────────────────────

const WINDOW_MS = 60_000;

/** key → 윈도 안에 들어온 요청 타임스탬프(ms) 목록. */
const hits = new Map<string, number[]>();

/**
 * 슬라이딩 윈도(1분) 안에서 key 당 perMinute 회까지 허용.
 * 호출 시점에 1건을 소비한다(허용된 경우에만 기록).
 */
export function checkRate(key: string, perMinute: number): { ok: boolean; retryAfterSec?: number } {
  const now = Date.now();
  const cutoff = now - WINDOW_MS;
  const recent = (hits.get(key) ?? []).filter((t) => t > cutoff);

  if (recent.length >= perMinute) {
    // 가장 오래된 요청이 윈도를 벗어날 때까지 남은 시간.
    const retryAfterSec = Math.max(1, Math.ceil((recent[0] + WINDOW_MS - now) / 1000));
    hits.set(key, recent);
    return { ok: false, retryAfterSec };
  }

  recent.push(now);
  hits.set(key, recent);
  return { ok: true };
}
