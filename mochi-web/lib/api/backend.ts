import "server-only";
import { SignJWT } from "jose";
import { serverEnv } from "@/lib/env";

// ─────────────────────────────────────────────────────────────
// BFF 백엔드 클라이언트 — 서버에서만 실행. 데모 access 토큰을 발급·캐시하고
// 모든 백엔드 호출에 Authorization을 주입한다. 브라우저는 토큰을 절대 보지 않는다.
//
// 토큰 전략: 백엔드 access JWT(HS256, iss/aud=mochi.app, 30분)를 AUTH_ACCESS_SECRET으로
// BFF가 직접 발급한다(자체발급). refresh는 백엔드 DB 해시 조회라 self-issued로 갱신 불가하므로,
// 운영 시크릿을 서버 env(MOCHI_JWT_SECRET)에만 두고 25분 캐시로 재발급한다. (DB 무변경)
// ─────────────────────────────────────────────────────────────

let cachedAccess: { token: string; expMs: number } | null = null;

async function getAccessToken(): Promise<string | null> {
  const now = Date.now();
  if (cachedAccess && cachedAccess.expMs > now + 60_000) return cachedAccess.token;

  // 1순위: AUTH_ACCESS_SECRET으로 access JWT 자체 발급 (백엔드 검증 구조 그대로 재현)
  if (serverEnv.jwtSecret && serverEnv.demoUserId) {
    try {
      const secret = new TextEncoder().encode(serverEnv.jwtSecret);
      const token = await new SignJWT({})
        .setProtectedHeader({ alg: "HS256", typ: "JWT" })
        .setIssuer("mochi.app")
        .setAudience("mochi.app")
        .setSubject(serverEnv.demoUserId)
        .setIssuedAt()
        .setExpirationTime("25m")
        .setJti(crypto.randomUUID())
        .sign(secret);
      cachedAccess = { token, expMs: now + 24 * 60_000 };
      return token;
    } catch {
      /* fallthrough */
    }
  }

  // 2순위: 백엔드 refresh (DB에 등록된 refresh token이 있을 때만 동작)
  if (serverEnv.demoRefreshToken) {
    try {
      const res = await fetch(`${serverEnv.backendBaseUrl}/api/v1/auth/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken: serverEnv.demoRefreshToken }),
        cache: "no-store",
      });
      if (res.ok) {
        const data = await res.json();
        const token: string | undefined = data.accessToken ?? data.access_token;
        if (token) {
          cachedAccess = { token, expMs: now + 25 * 60_000 };
          return token;
        }
      }
    } catch {
      /* fallthrough */
    }
  }

  // 3순위: 미리 발급된 정적 access token
  return serverEnv.demoAccessToken || null;
}

/** 백엔드로의 인증된 fetch. 라이브 데이터라 항상 no-store. */
export async function backendFetch(path: string, init?: RequestInit): Promise<Response> {
  const token = await getAccessToken();
  const headers = new Headers(init?.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  return fetch(`${serverEnv.backendBaseUrl}${path}`, {
    ...init,
    headers,
    cache: "no-store",
  });
}

// ── 엔드포인트 헬퍼 ─────────────────────────────────────────────

export interface IngestPayload {
  channel: string;
  url?: string;
  text?: string;
  imageRefs?: string[];
}

/** 캡처 접수 → 서버 부여 id. idempotency-key 헤더 필수. */
export async function ingest(payload: IngestPayload): Promise<Response> {
  return backendFetch("/api/v1/mochi_items", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Idempotency-Key": crypto.randomUUID(),
    },
    body: JSON.stringify(payload),
  });
}

/** 분석 진행 SSE 스트림 (Response.body를 그대로 클라로 프록시). */
export async function streamItem(id: string): Promise<Response> {
  return backendFetch(`/api/v1/mochi_items/${id}/stream`, {
    headers: { Accept: "text/event-stream" },
  });
}

export async function getItem(id: string): Promise<Response> {
  return backendFetch(`/api/v1/mochi_items/${id}`);
}

export async function recallFeed(): Promise<Response> {
  return backendFetch("/api/v1/recall/feed");
}

export async function recallUpcoming(): Promise<Response> {
  return backendFetch("/api/v1/recall/upcoming");
}

export async function listItems(): Promise<Response> {
  return backendFetch("/api/v1/mochi_items");
}

export async function similar(id: string): Promise<Response> {
  return backendFetch(`/api/v1/mochi_items/${id}/similar`);
}

/** 캡처 이미지 다운로드 URL (GCS signed) — 썸네일 프록시용. */
export async function imageDownloadUrl(objectKey: string): Promise<Response> {
  return backendFetch("/api/v1/mochi_items/images/download-url", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ objectKey }),
  });
}
