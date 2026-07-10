"use client";

/*
 * 여정 중 네트워크 응답의 라이브/폴백 집계 — 피날레의 "증거 한 줄"용.
 * 유일한 모드 흔적인 x-mochi-mode 응답 헤더를 세어 sessionStorage 에 쌓는다.
 * 통계는 장식이다 — 실패해도 여정에 어떤 영향도 주지 않는다.
 */

const KEY = "mochi-live-stats";

export interface LiveStats {
  live: number;
  fallback: number;
}

export function recordMode(mode: string | null): void {
  if (mode !== "live" && mode !== "fallback") return;
  try {
    const s = readStats();
    s[mode] += 1;
    sessionStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* private 모드 등 스토리지 불가 — 조용히 생략 */
  }
}

export function readStats(): LiveStats {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return { live: 0, fallback: 0 };
    const parsed = JSON.parse(raw) as Partial<LiveStats>;
    return {
      live: Number.isFinite(parsed.live) ? Number(parsed.live) : 0,
      fallback: Number.isFinite(parsed.fallback) ? Number(parsed.fallback) : 0,
    };
  } catch {
    return { live: 0, fallback: 0 };
  }
}
