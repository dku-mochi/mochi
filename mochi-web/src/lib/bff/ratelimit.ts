import "server-only";

/*
 * 인메모리 토큰버킷 — 데모 규모 남용 방지. 초과 시 429 가 아니라 **폴백 강등**
 * (호출부가 false 를 받으면 라이브 경로를 건너뛴다). Vercel 인스턴스별 독립이라
 * 정확한 전역 상한은 아니지만, 폴백 강등이라 초과해도 데모는 계속 완결된다.
 */

type BucketKind = "chat" | "search" | "ingest";

const buckets = new Map<BucketKind, { tokens: number; last: number }>();

function capacity(kind: BucketKind): number {
  if (kind === "ingest") {
    const env = Number(process.env.MOCHI_INGEST_PER_MINUTE);
    return Number.isFinite(env) && env > 0 ? env : 4;
  }
  return kind === "chat" ? 6 : 10;
}

/** 분당 capacity 개 리필. true = 라이브 허용, false = 폴백 강등 */
export function takeToken(kind: BucketKind): boolean {
  const cap = capacity(kind);
  const now = Date.now();
  const b = buckets.get(kind) ?? { tokens: cap, last: now };
  b.tokens = Math.min(cap, b.tokens + ((now - b.last) / 60_000) * cap);
  b.last = now;
  if (b.tokens < 1) {
    buckets.set(kind, b);
    return false;
  }
  b.tokens -= 1;
  buckets.set(kind, b);
  return true;
}
