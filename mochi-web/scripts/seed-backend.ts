import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SignJWT } from "jose";
import { seedPersonaSchema, type SeedInstance, type SeedPersona } from "../seed/schema";
import senaRaw from "../seed/personas/sena";
import dohyunRaw from "../seed/personas/dohyun";
import yunaRaw from "../seed/personas/yuna";

/*
 * 페르소나 시드 → 실백엔드 계정 시딩 (P7).
 *
 * 사용:
 *   1) (사람) prod DB 에 페르소나 user row 3건 삽입 후 UUID 를 env 에 등록
 *      MOCHI_PERSONA_UUID_SENA / _DOHYUN / _YUNA (+ MOCHI_BACKEND_URL, MOCHI_JWT_SECRET)
 *   2) npm run seed:backend            — 시딩 + 건수·검색 스모크
 *      npm run seed:backend -- --smoke — 채팅 1턴 스모크까지
 *   3) 산출된 seed/backend-ids.json(uuid↔slug) 을 커밋
 *   4) (사람) 백엔드 scripts/backfill_embeddings.py 실행 — 검색 인덱싱
 *
 * 규약:
 * - `confirmedInstances` 지정 → LLM 분석 우회, 결정론 시딩 (openapi MochiItemCreateRequest).
 * - Idempotency-Key `{persona}:{slug}:v1` — 재실행해도 중복 생성 없음.
 * - capturedAt 은 계약에 없다 — 시간축(며칠 전·D-day)은 웹 시드 단독 소유.
 *   payload 의 date/deadline 만 실행 시점 KST 기준으로 절대화해 보낸다.
 */

const personas: SeedPersona[] = [senaRaw, dohyunRaw, yunaRaw].map((p) =>
  seedPersonaSchema.parse(p),
);

/* ── env (.env.local 수동 로드 — tsx 는 자동 로드하지 않는다) ── */

function loadEnvLocal() {
  const path = join(process.cwd(), ".env.local");
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    const [, key, raw] = m;
    if (process.env[key] === undefined) {
      process.env[key] = raw.replace(/^["']|["']$/g, "");
    }
  }
}
loadEnvLocal();

function backendBase(): string {
  const raw = process.env.MOCHI_BACKEND_URL?.trim();
  if (!raw) throw new Error("MOCHI_BACKEND_URL 이 없습니다 (.env.local)");
  const base = raw.replace(/\/+$/, "");
  return base.endsWith("/api/v1") ? base : `${base}/api/v1`;
}

/* ── JWT (백엔드 HS256AccessTokenIssuer 동형 — src/lib/bff/token.ts 와 같은 클레임) ── */

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

/* ── 상대 → 절대 날짜 (KST 고정 — seedRuntime 과 같은 규칙) ── */

const DAY = 86_400_000;
const KST = 9 * 3_600_000;

function kstDateStr(daysFromNow: number): string {
  const d = new Date(Date.now() + KST + daysFromNow * DAY);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(
    d.getUTCDate(),
  ).padStart(2, "0")}`;
}

function toConfirmedInstance(inst: SeedInstance) {
  const p = inst.payload;
  const payload: Record<string, string> = {};
  if (p?.title) payload.title = p.title;
  if (p?.dateInDays !== undefined) payload.date = kstDateStr(p.dateInDays);
  if (p?.time) payload.time = p.time;
  if (p?.deadlineInDays !== undefined) payload.deadline = kstDateStr(p.deadlineInDays);
  if (p?.person) payload.person = p.person;
  if (p?.topic) payload.topic = p.topic;
  if (p?.url) payload.url = p.url;
  if (p?.note) payload.note = p.note;
  return {
    intentType: inst.intentType,
    label: inst.label ?? null,
    ...(Object.keys(payload).length > 0 ? { payload } : {}),
  };
}

/* ── 시딩 ── */

interface SeedReport {
  persona: string;
  created: number;
  reused: number;
  failed: string[];
}

async function seedPersona(
  base: string,
  persona: SeedPersona,
  uuid: string,
  idMap: Record<string, string>,
): Promise<SeedReport> {
  const token = await signToken(uuid);
  const report: SeedReport = { persona: persona.slug, created: 0, reused: 0, failed: [] };

  for (const item of persona.items) {
    const body = {
      channel: item.channel,
      url: item.url ?? null,
      text: item.text ?? null,
      userMemo: item.userMemo ?? null,
      analysisOcrText: item.ocrText ?? null,
      category: item.category,
      summary: item.summary,
      confirmedInstances: item.instances.map(toConfirmedInstance),
    };
    try {
      const res = await fetch(`${base}/mochi_items`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          "Idempotency-Key": `${persona.slug}:${item.slug}:v1`,
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20_000),
      });
      if (!res.ok) {
        report.failed.push(`${item.slug} → HTTP ${res.status} ${(await res.text()).slice(0, 160)}`);
        continue;
      }
      const created = (await res.json()) as { id: string };
      idMap[created.id] = item.slug;
      // 멱등 재실행은 같은 id 를 돌려준다 — 201/200 구분 없이 카운트만
      if (res.status === 201) report.created += 1;
      else report.reused += 1;
    } catch (err) {
      report.failed.push(`${item.slug} → ${(err as Error).message}`);
    }
  }
  return report;
}

/* ── 스모크 ── */

async function smoke(base: string, persona: SeedPersona, uuid: string, chatToo: boolean) {
  const token = await signToken(uuid);
  const auth = { authorization: `Bearer ${token}` };

  const list = await fetch(`${base}/mochi_items?limit=100`, {
    headers: auth,
    signal: AbortSignal.timeout(15_000),
  });
  const items = list.ok ? ((await list.json()) as { items?: unknown[] }) : null;
  const count = Array.isArray(items?.items) ? items.items.length : "?";
  console.log(`  [${persona.slug}] 계정 아이템 ${count}건 (시드 ${persona.items.length}건)`);

  const query = persona.suggestedSearch[0];
  const search = await fetch(`${base}/search`, {
    method: "POST",
    headers: { ...auth, "content-type": "application/json" },
    body: JSON.stringify({ query }),
    signal: AbortSignal.timeout(30_000),
  });
  if (search.ok) {
    const body = (await search.json()) as { citations: unknown[] };
    console.log(`  [${persona.slug}] 검색 "${query}" → citations ${body.citations.length}건`);
  } else {
    console.log(`  [${persona.slug}] 검색 스모크 실패 HTTP ${search.status} (embeddings backfill 전이면 정상)`);
  }

  if (!chatToo) return;
  const chat = await fetch(`${base}/conversations/${crypto.randomUUID()}/messages`, {
    method: "POST",
    headers: { ...auth, "content-type": "application/json" },
    body: JSON.stringify({ text: persona.suggestedChat[0] }),
    signal: AbortSignal.timeout(90_000),
  });
  if (chat.ok && chat.body) {
    const text = await chat.text();
    const done = text.includes("event: done");
    console.log(`  [${persona.slug}] 채팅 1턴 → ${done ? "done 수신 ✓" : "done 미수신 ✗"}`);
  } else {
    console.log(`  [${persona.slug}] 채팅 스모크 실패 HTTP ${chat.status}`);
  }
}

/* ── main ── */

async function main() {
  const chatToo = process.argv.includes("--smoke");
  const base = backendBase();
  console.log(`시딩 대상: ${base}\n`);

  const idMapPath = join(process.cwd(), "seed", "backend-ids.json");
  const idMap: Record<string, string> = existsSync(idMapPath)
    ? (JSON.parse(readFileSync(idMapPath, "utf8")) as Record<string, string>)
    : {};

  const reports: SeedReport[] = [];
  for (const persona of personas) {
    const uuid = process.env[persona.uuidEnvKey]?.trim();
    if (!uuid) {
      console.warn(`⚠ ${persona.uuidEnvKey} 미설정 — ${persona.slug} 건너뜀 (사람 단계: user row 삽입 후 env 등록)`);
      continue;
    }
    console.log(`→ ${persona.slug} (${persona.items.length}건) 시딩 중…`);
    reports.push(await seedPersona(base, persona, uuid, idMap));
  }

  if (reports.length === 0) {
    console.error("\n✗ 시딩된 페르소나가 없습니다 — env 를 확인하세요.");
    process.exit(1);
  }

  const sorted = Object.fromEntries(Object.entries(idMap).sort(([, a], [, b]) => a.localeCompare(b)));
  writeFileSync(idMapPath, `${JSON.stringify(sorted, null, 2)}\n`);
  console.log(`\nbackend-ids.json 갱신 — 매핑 ${Object.keys(sorted).length}건 (커밋 대상)`);

  console.log("\n리포트:");
  for (const r of reports) {
    console.log(`  ${r.persona}: 생성 ${r.created} · 멱등재사용 ${r.reused} · 실패 ${r.failed.length}`);
    r.failed.forEach((f) => console.log(`    ✗ ${f}`));
  }

  console.log("\n스모크:");
  for (const persona of personas) {
    const uuid = process.env[persona.uuidEnvKey]?.trim();
    if (uuid) await smoke(base, persona, uuid, chatToo);
  }

  const failedTotal = reports.reduce((n, r) => n + r.failed.length, 0);
  if (failedTotal > 0) {
    console.error(`\n✗ 실패 ${failedTotal}건 — 위 로그 확인`);
    process.exit(1);
  }
  console.log("\n✓ 시딩 완료. 다음: (사람) backfill_embeddings.py 실행 → backend-ids.json 커밋");
}

main().catch((err) => {
  console.error("✗ 시더 중단:", err);
  process.exit(1);
});
