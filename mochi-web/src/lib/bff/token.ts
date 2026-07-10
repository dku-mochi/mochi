import "server-only";

import { createHash } from "node:crypto";
import { SignJWT } from "jose";
import { getPersona } from "@seed/index";

/*
 * 페르소나 → 백엔드 access JWT 발급 (HS256AccessTokenIssuer 와 동일 클레임).
 * 정본: mochi-backend app/modules/auth/infrastructure/jwt_issuer.py —
 * iss/aud=mochi.app, sub=user UUID, iat/exp/jti, TTL 30분. 만료 5분 전 재발행 캐시.
 */

const ISSUER = "mochi.app";
const AUDIENCE = "mochi.app";
const TTL_MS = 30 * 60_000;
const REFRESH_MARGIN_MS = 5 * 60_000;

const cache = new Map<string, { token: string; expiresAt: number }>();

/**
 * 페르소나 실계정 UUID — env `MOCHI_PERSONA_UUID_{SLUG}` 단독.
 * 공용 폴백 계정은 두지 않는다: UUID 미설정이면 라이브를 포기하고 canned 폴백으로
 * 강등하는 게, 다른 계정의 기록으로 답하는 것보다 낫다 (교차 계정 누수 차단).
 */
export function personaUuid(personaSlug: string): string | null {
  const persona = getPersona(personaSlug);
  if (!persona) return null;
  return process.env[persona.uuidEnvKey]?.trim() || null;
}

export async function personaToken(personaSlug: string): Promise<string | null> {
  const secret = process.env.MOCHI_JWT_SECRET?.trim();
  const uuid = personaUuid(personaSlug);
  if (!secret || !uuid) return null;

  const now = Date.now();
  // 시크릿 지문을 키에 포함 — 회전 직후 구 시크릿 서명 토큰을 재사용하지 않게
  const cacheKey = `${uuid}:${createHash("sha256").update(secret).digest("hex").slice(0, 12)}`;
  const hit = cache.get(cacheKey);
  if (hit && hit.expiresAt - now > REFRESH_MARGIN_MS) return hit.token;

  const expiresAt = now + TTL_MS;
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(uuid)
    .setIssuedAt(Math.floor(now / 1000))
    .setExpirationTime(Math.floor(expiresAt / 1000))
    .setJti(crypto.randomUUID())
    .sign(new TextEncoder().encode(secret));

  cache.set(cacheKey, { token, expiresAt });
  return token;
}
