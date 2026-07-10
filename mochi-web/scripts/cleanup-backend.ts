import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { SignJWT } from "jose";
import { seedPersonaSchema, type SeedPersona } from "../seed/schema";
import senaRaw from "../seed/personas/sena";
import dohyunRaw from "../seed/personas/dohyun";
import yunaRaw from "../seed/personas/yuna";

/*
 * 페르소나 공용 계정 청소 — 데모 방문자들이 라이브로 보낸 테스트 기록을 정리한다.
 *
 * 페르소나 계정은 모든 방문자가 공유하므로, 시딩분(seed/backend-ids.json 의 uuid)만
 * 남기고 나머지를 지운다. 화면 피드는 시드+내 세션 오버레이만 렌더해 남의 기록이
 * 보이지 않지만, 채팅/검색의 LLM 답변 텍스트에는 섞일 수 있다 — 심사 전에 1회 실행.
 *
 * 사용:
 *   npm run seed:cleanup             # dry-run — 지울 대상만 나열
 *   npm run seed:cleanup -- --apply  # 실제 삭제
 */

const personas: SeedPersona[] = [senaRaw, dohyunRaw, yunaRaw].map((p) =>
  seedPersonaSchema.parse(p),
);

const APPLY = process.argv.includes("--apply");

/* ── env (.env.local 수동 로드 — seed-backend.ts 와 같은 규칙) ── */

function loadEnvLocal() {
  const path = join(process.cwd(), ".env.local");
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    const [, key, rawValue] = m;
    if (process.env[key] !== undefined) continue;
    let value = rawValue.trim();
    if (/^".*"$/.test(value) || /^'.*'$/.test(value)) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/, "").trim();
    }
    process.env[key] = value;
  }
}
loadEnvLocal();

function backendBase(): string {
  const raw = process.env.MOCHI_BACKEND_URL?.trim();
  if (!raw) throw new Error("MOCHI_BACKEND_URL 이 없습니다 (.env.local)");
  const base = raw.replace(/\/+$/, "");
  return base.endsWith("/api/v1") ? base : `${base}/api/v1`;
}

async function signToken(uuid: string): Promise<string> {
  const secret = process.env.MOCHI_JWT_SECRET?.trim();
  if (!secret) throw new Error("MOCHI_JWT_SECRET 이 없습니다 (.env.local)");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer("mochi.app")
    .setAudience("mochi.app")
    .setSubject(uuid)
    .setIssuedAt(now)
    .setExpirationTime(now + 1800)
    .setJti(crypto.randomUUID())
    .sign(new TextEncoder().encode(secret));
}

/* ── 청소 ── */

function loadSeededIds(): Set<string> {
  const path = join(process.cwd(), "seed", "backend-ids.json");
  if (!existsSync(path)) {
    throw new Error("seed/backend-ids.json 이 없습니다 — 먼저 npm run seed:backend");
  }
  const map = JSON.parse(readFileSync(path, "utf8")) as Record<string, string>;
  return new Set(Object.keys(map));
}

interface ListedItem {
  id: string;
  text?: string | null;
  userMemo?: string | null;
  url?: string | null;
}

async function cleanupPersona(
  base: string,
  persona: SeedPersona,
  uuid: string,
  seeded: Set<string>,
): Promise<void> {
  const token = await signToken(uuid);
  const auth = { authorization: `Bearer ${token}` };

  const res = await fetch(`${base}/mochi_items?limit=500`, { headers: auth });
  if (!res.ok) {
    console.error(`  [${persona.slug}] 목록 조회 실패 — HTTP ${res.status}`);
    return;
  }
  const body = (await res.json()) as { items?: ListedItem[] };
  const all = body.items ?? [];
  const strays = all.filter((it) => !seeded.has(it.id));
  console.log(
    `  [${persona.slug}] 전체 ${all.length}건 — 시딩분 ${all.length - strays.length}건 유지, 방문자 기록 ${strays.length}건 ${APPLY ? "삭제" : "발견(dry-run)"}`,
  );

  for (const it of strays) {
    const label = (it.text ?? it.userMemo ?? it.url ?? "(이미지)").slice(0, 40);
    if (!APPLY) {
      console.log(`    - ${it.id}  ${label}`);
      continue;
    }
    const del = await fetch(`${base}/mochi_items/${it.id}`, {
      method: "DELETE",
      headers: auth,
    });
    console.log(`    ${del.ok ? "✓ 삭제" : `✗ 실패(HTTP ${del.status})`}  ${it.id}  ${label}`);
  }
}

async function main() {
  const base = backendBase();
  const seeded = loadSeededIds();
  console.log(
    `페르소나 공용 계정 청소 ${APPLY ? "(--apply: 실제 삭제)" : "(dry-run — 삭제하려면 --apply)"}`,
  );

  for (const persona of personas) {
    const uuid = process.env[persona.uuidEnvKey]?.trim();
    if (!uuid) {
      console.log(`  [${persona.slug}] ${persona.uuidEnvKey} 미설정 — 건너뜀`);
      continue;
    }
    await cleanupPersona(base, persona, uuid, seeded);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
