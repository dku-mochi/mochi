import "server-only";

import { createHash } from "node:crypto";
import type { AnalyzedItemWire, ProposalType } from "@/lib/api/wire";
import { parseSseStream } from "@/lib/sse/parse";
import { chatWireEvents, type ChatLiveContext, type IngestInput } from "./fallback";
import { personaToken } from "./token";
import type { OutEvent } from "./sse";

/*
 * 라이브 백엔드 프록시 — fallback-first 규약의 앞단.
 * 원칙: 어떤 실패(미설정·타임아웃·비 2xx·스트림 절단)도 클라이언트에 새지 않는다.
 * 스트림은 끊지 않고 서버가 폴백 이벤트를 이어붙여 완결하고, 단발 요청은 폴백 응답으로
 * 강등된다. 클라이언트는 `x-mochi-mode` 헤더 외엔 모드를 알 수 없다.
 */

const CHAT_FIRST_BYTE_MS = 8_000;
const CHAT_INTER_EVENT_MS = 15_000;
const ANALYSIS_FIRST_BYTE_MS = 8_000;
// 분석 node 사이 간격은 LLM 파이프라인 대기 포함 — 백엔드 자체 deadline 이 있어 넉넉히
const ANALYSIS_INTER_EVENT_MS = 75_000;
const JSON_TIMEOUT_MS = 12_000;
// GCS PUT 은 이미지 bytes 전송 — JSON 왕복보다 넉넉히
const UPLOAD_TIMEOUT_MS = 30_000;
const ITEM_POLL_RETRIES = 4;
const ITEM_POLL_INTERVAL_MS = 1_200;

export interface Upstream {
  base: string;
  token: string;
}

/** MOCHI_BACKEND_URL 정규화 — `/api/v1` 유무 양쪽 허용 */
export function backendBase(): string | null {
  const raw = process.env.MOCHI_BACKEND_URL?.trim();
  if (!raw) return null;
  const base = raw.replace(/\/+$/, "");
  return base.endsWith("/api/v1") ? base : `${base}/api/v1`;
}

/** 라이브 사용 가능 여부 — 킬스위치·env·페르소나 계정까지 한 번에 판정 */
export async function prepareUpstream(personaSlug: string): Promise<Upstream | null> {
  if (process.env.MOCHI_FORCE_FALLBACK === "1") return null;
  const base = backendBase();
  if (!base) return null;
  try {
    const token = await personaToken(personaSlug);
    return token ? { base, token } : null;
  } catch {
    return null;
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 클라 입력이 upstream URL path 에 실리기 전의 allowlist — 경로 주입 차단 */
export function isUuid(id: string): boolean {
  return UUID_RE.test(id);
}

export const isLiveItemId = isUuid;

function authHeaders(up: Upstream): Record<string, string> {
  return {
    authorization: `Bearer ${up.token}`,
    "content-type": "application/json",
  };
}

/* ── 타임아웃 레이스 ─────────────────────────────── */

const STALL = Symbol("stall");

async function raceStall<T>(p: Promise<T>, ms: number): Promise<T | typeof STALL> {
  let timer!: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([
      p,
      new Promise<typeof STALL>((resolve) => {
        timer = setTimeout(() => resolve(STALL), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/* ── 채팅: 패스스루 + 이어붙임 ─────────────────────────────── */

interface LiveChatOpts extends Upstream {
  conversationId: string;
  personaSlug: string;
  text: string;
  liveContext?: ChatLiveContext;
  /** 클라이언트 단절 신호 (req.signal) */
  signal?: AbortSignal;
}

async function openChatStream(opts: LiveChatOpts, ac: AbortController): Promise<Response> {
  const post = (cid: string) =>
    fetch(`${opts.base}/conversations/${cid}/messages`, {
      method: "POST",
      headers: authHeaders(opts),
      body: JSON.stringify({ text: opts.text }),
      signal: ac.signal,
      cache: "no-store",
    });

  let res = await post(opts.conversationId);
  if (res.status === 409) {
    // 동시 run — 새 conversationId 로 1회 재시도 (서버측 대화 연속성보다 완결 우선)
    void res.body?.cancel().catch(() => {});
    res = await post(crypto.randomUUID());
  }
  return res;
}

/**
 * 라이브 채팅 개시 — 응답 헤더(first-byte 8s)까지 확인한 뒤 스트림 제너레이터를
 * 돌려준다. 개시 실패면 null (라우트가 폴백으로 강등 — `x-mochi-mode` 도 정직해진다).
 */
export async function openLiveChat(opts: LiveChatOpts): Promise<AsyncGenerator<OutEvent> | null> {
  const ac = new AbortController();
  const onClientAbort = () => ac.abort();
  opts.signal?.addEventListener("abort", onClientAbort, { once: true });
  try {
    const res = await raceStall(openChatStream(opts, ac), CHAT_FIRST_BYTE_MS);
    if (res === STALL || !res.ok || !res.body) throw new Error("chat_upstream_unavailable");
    return chatStitched(res.body, ac, opts, onClientAbort);
  } catch {
    opts.signal?.removeEventListener("abort", onClientAbort);
    ac.abort();
    return null;
  }
}

/**
 * 개시된 라이브 스트림의 패스스루 — inter-event 15s 초과·오류 시 스트림을 끊지 않고
 * 폴백 이벤트를 이어붙여 완결한다. 본문 텍스트가 이미 나간 뒤라면 폴백 재생 대신
 * done 으로 조용히 완결한다 (본문이 두 번 시작되는 것보다 짧은 답이 낫다).
 */
async function* chatStitched(
  body: ReadableStream<Uint8Array>,
  ac: AbortController,
  opts: LiveChatOpts,
  onClientAbort: () => void,
): AsyncGenerator<OutEvent> {
  let sawDelta = false;
  let sawDone = false;
  let sawContextCitation = false;
  let maxCitationIndex = 0;
  let runId = `live_${crypto.randomUUID().slice(0, 8)}`;

  try {
    try {
      const events = parseSseStream(body, ac.signal);
      // 첫 실이벤트는 LLM 대기 포함 — 개시 직후 주석(: stream-open)은 파서가 거른다
      let deadline = CHAT_INTER_EVENT_MS;
      while (true) {
        const nextP = events.next();
        const result = await raceStall(nextP, deadline);
        if (result === STALL) {
          nextP.catch(() => {});
          ac.abort(); // 폴백 재생 동안 upstream 소켓을 붙들지 않는다
          throw new Error("chat_stream_stalled");
        }
        if (result.done) break;
        deadline = CHAT_INTER_EVENT_MS;

        let data: unknown;
        try {
          data = JSON.parse(result.value.data);
        } catch {
          continue;
        }
        if (data && typeof data === "object" && "run_id" in data) {
          runId = String((data as { run_id: unknown }).run_id);
        }
        const kind = result.value.event;
        if (kind === "error") {
          ac.abort();
          throw new Error("chat_upstream_error");
        }
        if (kind === "message_delta") sawDelta = true;
        if (kind === "citation" && data && typeof data === "object") {
          const citation = data as { item_id?: unknown; index?: unknown };
          if (citation.item_id === opts.liveContext?.id) sawContextCitation = true;
          if (typeof citation.index === "number") maxCitationIndex = Math.max(maxCitationIndex, citation.index);
        }
        if (kind === "done") {
          sawDone = true;
          if (opts.liveContext && !sawContextCitation) {
            yield {
              event: "citation",
              data: {
                run_id: runId,
                index: maxCitationIndex + 1,
                item_id: opts.liveContext.id,
                title: opts.liveContext.title,
                snippet: opts.liveContext.summary,
              },
            };
          }
        }
        yield { event: kind, data };
        if (kind === "done") return;
      }
      if (!sawDone) throw new Error("chat_stream_ended_early");
    } catch (err) {
      if (opts.signal?.aborted) return; // 클라가 끊음 — 이어붙일 대상 없음
      void err;
      if (sawDelta) {
        // 본문이 나간 뒤의 절단 — 완결 신호만 이어붙인다
        if (opts.liveContext && !sawContextCitation) {
          yield {
            event: "citation",
            data: {
              run_id: runId,
              index: maxCitationIndex + 1,
              item_id: opts.liveContext.id,
              title: opts.liveContext.title,
              snippet: opts.liveContext.summary,
            },
          };
        }
        yield {
          event: "done",
          data: { run_id: runId, message_id: `stitch_${crypto.randomUUID().slice(0, 8)}` },
        };
      } else {
        // 본문 전 실패 — 폴백 대본 전체로 완결 (delayMs 페이싱은 sseResponse 가 소화)
        yield* arrayToAsync(chatWireEvents(opts.personaSlug, opts.text, opts.liveContext));
      }
    }
  } finally {
    opts.signal?.removeEventListener("abort", onClientAbort);
    ac.abort(); // upstream 소켓 정리
  }
}

async function* arrayToAsync(events: OutEvent[]): AsyncGenerator<OutEvent> {
  for (const e of events) yield e;
}

/* ── 검색 (단발 JSON) ─────────────────────────────── */

/** 라이브 검색 — 실패 시 null (호출부가 폴백 강등) */
export async function liveSearch(
  up: Upstream,
  query: string,
  clientSignal?: AbortSignal,
): Promise<unknown | null> {
  try {
    const signals = [AbortSignal.timeout(JSON_TIMEOUT_MS)];
    if (clientSignal) signals.push(clientSignal);
    const res = await fetch(`${up.base}/search`, {
      method: "POST",
      headers: authHeaders(up),
      body: JSON.stringify({ query }),
      signal: AbortSignal.any(signals),
      cache: "no-store",
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

/* ── 채팅 proposal 확정 실행 ─────────────────────────────── */

function stringRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function camelPayload(value: unknown): Record<string, unknown> {
  const raw = stringRecord(value);
  const out: Record<string, unknown> = {};
  for (const [key, field] of Object.entries(raw)) {
    const camel = key.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());
    out[camel] = field;
  }
  return out;
}

export type LiveProposalResult = "confirmed" | "preview" | "expired" | "failed";

interface StoredProposal {
  type: ProposalType;
  payload: Record<string, unknown>;
}

const PROPOSAL_TYPES = new Set<ProposalType>([
  "item_update",
  "item_delete",
  "create_schedule",
  "reminder",
  "create_memo",
]);

async function storedProposal(
  up: Upstream,
  conversationId: string,
  proposalId: string,
): Promise<StoredProposal | "expired" | "failed"> {
  let sawSnapshot = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetch(`${up.base}/conversations/${conversationId}`, {
        headers: { authorization: `Bearer ${up.token}` },
        signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
        cache: "no-store",
      });
      if (response.status === 404) return "expired";
      if (response.ok) {
        sawSnapshot = true;
        const snapshot = (await response.json()) as {
          messages?: Array<{ proposals?: Array<Record<string, unknown>> }>;
        };
        for (const message of snapshot.messages ?? []) {
          for (const proposal of message.proposals ?? []) {
            if (proposal.id !== proposalId || typeof proposal.type !== "string") continue;
            if (!PROPOSAL_TYPES.has(proposal.type as ProposalType)) return "expired";
            return {
              type: proposal.type as ProposalType,
              payload: stringRecord(proposal.payload),
            };
          }
        }
      }
    } catch {
      if (attempt === 2) return "failed";
    }
    // proposal 이벤트 직후 assistant 스냅샷 영속이 끝나기 전 누를 수 있어 짧게 재조회한다.
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return sawSnapshot ? "expired" : "failed";
}

export async function executeLiveProposal(
  up: Upstream,
  conversationId: string,
  proposalId: string,
): Promise<LiveProposalResult> {
  const stored = await storedProposal(up, conversationId, proposalId);
  if (stored === "expired" || stored === "failed") return stored;
  const { type, payload } = stored;
  // 공유 페르소나의 기존 기록을 바꾸는 파괴적 작업과 기기 알림은 웹에서 실행하지 않는다.
  if (type === "item_update" || type === "item_delete" || type === "reminder") return "preview";
  let action: Response;
  try {
    if (type === "create_schedule") {
      const confirmed = Array.isArray(payload.confirmed_instances)
        ? payload.confirmed_instances.map((value) => {
            const instance = stringRecord(value);
            return {
              intentType: instance.intent_type,
              payload: camelPayload(instance.payload),
              ...(typeof instance.label === "string" ? { label: instance.label } : {}),
            };
          })
        : [];
      if (confirmed.length === 0) return "failed";
      action = await fetch(`${up.base}/mochi_items`, {
        method: "POST",
        headers: { ...authHeaders(up), "Idempotency-Key": proposalId },
        body: JSON.stringify({
          channel: "chat",
          text: typeof payload.text === "string" ? payload.text : null,
          confirmedInstances: confirmed,
          category: typeof payload.category === "string" ? payload.category : null,
          summary: typeof payload.summary === "string" ? payload.summary : null,
        }),
        signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
        cache: "no-store",
      });
    } else if (type === "create_memo") {
      const text = typeof payload.text === "string" ? payload.text.trim() : "";
      if (!text) return "failed";
      action = await fetch(`${up.base}/mochi_items`, {
        method: "POST",
        headers: { ...authHeaders(up), "Idempotency-Key": proposalId },
        body: JSON.stringify({ channel: "chat", text }),
        signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
        cache: "no-store",
      });
    } else {
      return "failed";
    }
  } catch {
    return "failed";
  }

  if (action.status === 404) return "expired";
  if (!action.ok) return "failed";

  try {
    await fetch(`${up.base}/conversations/${conversationId}/proposals/${proposalId}`, {
      method: "PATCH",
      headers: authHeaders(up),
      body: JSON.stringify({ status: "confirmed" }),
      signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
      cache: "no-store",
    });
  } catch {
    // 실행 자체는 완료됐다. 카드 상태 영속은 iOS와 같은 best-effort다.
  }
  return "confirmed";
}

export async function cancelLiveProposal(
  up: Upstream,
  conversationId: string,
  proposalId: string,
): Promise<void> {
  try {
    await fetch(`${up.base}/conversations/${conversationId}/proposals/${proposalId}`, {
      method: "PATCH",
      headers: authHeaders(up),
      body: JSON.stringify({ status: "cancelled" }),
      signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
      cache: "no-store",
    });
  } catch {
    /* 취소 카드 영속은 best-effort */
  }
}

/* ── 라이브 분석 (S2): ingest → 진행 SSE → 본문 재조회 ─────────────────────────────── */

/** 라이브 ingest — 실패 시 null (호출부가 폴백 id 강등) */
export async function liveIngest(
  up: Upstream,
  personaSlug: string,
  input: IngestInput,
): Promise<string | null> {
  // 같은 입력의 네트워크 재시도/재전송이 중복 기록이 되지 않게 — 내용 기반 안정 멱등키
  const idempotencyKey = `web:${personaSlug}:${createHash("sha256")
    .update(JSON.stringify(input))
    .digest("hex")
    .slice(0, 32)}`;
  try {
    const res = await fetch(`${up.base}/mochi_items`, {
      method: "POST",
      headers: {
        ...authHeaders(up),
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify({
        channel: "appDirectInput",
        text: input.text ?? null,
        url: input.url ?? null,
        userMemo: input.memo ?? null,
      }),
      signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
      cache: "no-store",
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { id?: string };
    return typeof body.id === "string" && isLiveItemId(body.id) ? body.id : null;
  } catch {
    return null;
  }
}

/* ── 이미지 ingest: presign → GCS PUT → imageRefs ingest ─────────────────────────────── */

interface ImageIngestInput {
  bytes: Uint8Array<ArrayBuffer>;
  mimeType: string;
  memo?: string;
}

/**
 * 라이브 이미지 ingest — 백엔드 presign 으로 Signed PUT URL 을 받아 서버가 bytes 를
 * 대신 올리고(브라우저 직PUT 은 버킷 CORS 필요), imageRefs 로 본 ingest 를 완결한다.
 * 어느 단이라도 실패하면 null (호출부가 폴백 강등).
 */
export async function liveImageIngest(
  up: Upstream,
  personaSlug: string,
  input: ImageIngestInput,
): Promise<string | null> {
  try {
    const sha256 = createHash("sha256").update(input.bytes).digest("hex");
    const presignRes = await fetch(`${up.base}/mochi_items/presign`, {
      method: "POST",
      headers: authHeaders(up),
      body: JSON.stringify({ sha256, mimeType: input.mimeType }),
      signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
      cache: "no-store",
    });
    if (!presignRes.ok) return null;
    const presign = (await presignRes.json()) as { objectKey?: string; uploadURL?: string };
    // 업로드 대상은 신뢰하는 백엔드가 발급한 GCS 서명 URL 만 (SSRF 여지 차단)
    if (!presign.objectKey || !presign.uploadURL?.startsWith("https://storage.googleapis.com/")) {
      return null;
    }

    const put = await fetch(presign.uploadURL, {
      method: "PUT",
      // content-type 은 V4 서명에 바인딩 — presign 요청과 동일값이어야 한다
      headers: { "content-type": input.mimeType },
      body: input.bytes,
      signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS),
      cache: "no-store",
    });
    if (!put.ok) return null;

    // 같은 이미지+메모의 재전송이 중복 기록이 되지 않게 — 텍스트 경로처럼 입력 전체 기반
    // 멱등키 (memo 가 다르면 새 아이템: 백엔드 replay 는 payload 를 비교하지 않는다)
    const idempotencyKey = `web:${personaSlug}:img:${createHash("sha256")
      .update(`${sha256}:${input.memo?.trim() ?? ""}`)
      .digest("hex")
      .slice(0, 28)}`;
    const res = await fetch(`${up.base}/mochi_items`, {
      method: "POST",
      headers: {
        ...authHeaders(up),
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify({
        channel: "screenshot",
        userMemo: input.memo?.trim() || null,
        imageRefs: [
          {
            objectKey: presign.objectKey,
            mimeType: input.mimeType,
            byteSize: input.bytes.byteLength,
            sha256,
          },
        ],
      }),
      signal: AbortSignal.timeout(JSON_TIMEOUT_MS),
      cache: "no-store",
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { id?: string };
    return typeof body.id === "string" && isLiveItemId(body.id) ? body.id : null;
  } catch {
    return null;
  }
}

interface LiveAnalysisOpts extends Upstream {
  itemId: string;
  signal?: AbortSignal;
}

/**
 * 라이브 분석 스트림 개시 — 응답 헤더(first-byte 8s)까지 확인 후 제너레이터를 돌려준다.
 * 개시 실패면 null (라우트가 폴백 연출로 강등).
 */
export async function openLiveAnalysis(
  opts: LiveAnalysisOpts,
): Promise<AsyncGenerator<OutEvent> | null> {
  const ac = new AbortController();
  const onClientAbort = () => ac.abort();
  opts.signal?.addEventListener("abort", onClientAbort, { once: true });
  try {
    const res = await raceStall(
      fetch(`${opts.base}/mochi_items/${opts.itemId}/stream`, {
        headers: { authorization: `Bearer ${opts.token}` },
        signal: ac.signal,
        cache: "no-store",
      }),
      ANALYSIS_FIRST_BYTE_MS,
    );
    if (res === STALL || !res.ok || !res.body) throw new Error("analysis_upstream_unavailable");
    return analysisStitched(res.body, ac, opts, onClientAbort);
  } catch {
    opts.signal?.removeEventListener("abort", onClientAbort);
    ac.abort();
    return null;
  }
}

/**
 * 개시된 분석 스트림의 패스스루 — 절단·타임아웃·failed 는 final 로 이어붙여 완결한다.
 * (분석 자체는 백엔드 worker 가 계속 진행 — items 재조회가 결과를 메운다)
 */
async function* analysisStitched(
  body: ReadableStream<Uint8Array>,
  ac: AbortController,
  opts: LiveAnalysisOpts,
  onClientAbort: () => void,
): AsyncGenerator<OutEvent> {
  let sawAny = false;
  try {
    try {
      const events = parseSseStream(body, ac.signal);
      let deadline = ANALYSIS_INTER_EVENT_MS;
      while (true) {
        const nextP = events.next();
        const result = await raceStall(nextP, deadline);
        if (result === STALL) {
          nextP.catch(() => {});
          ac.abort(); // 이어붙임 동안 upstream 소켓을 붙들지 않는다
          throw new Error("analysis_stream_stalled");
        }
        if (result.done) break;
        deadline = ANALYSIS_INTER_EVENT_MS;

        let data: unknown;
        try {
          data = JSON.parse(result.value.data);
        } catch {
          continue;
        }
        const kind = result.value.event;
        // 백엔드 failed 도 데모에선 final 로 완결 — 기록 자체는 남았고, 본문 재조회가 정직하게 처리
        if (kind === "failed") {
          ac.abort();
          throw new Error("analysis_failed");
        }
        sawAny = true;
        yield { event: kind, data };
        if (kind === "final") return;
      }
      throw new Error("analysis_stream_ended_early");
    } catch (err) {
      if (opts.signal?.aborted) return;
      void err;
      if (!sawAny) {
        yield { event: "node", data: { lifecycle_kind: "analyzing" }, delayMs: 400 };
      }
      yield { event: "final", data: { lifecycle_kind: "analyzed" }, delayMs: 600 };
    }
  } finally {
    opts.signal?.removeEventListener("abort", onClientAbort);
    ac.abort();
  }
}

/* ── 아이템 본문 재조회 → AnalyzedItemWire 매핑 ─────────────────────────────── */

interface LiveItemResponse {
  id: string;
  url?: string | null;
  text?: string | null;
  userMemo?: string | null;
  summary?: string | null;
  category?: string | null;
  shoppingProductQuery?: string | null;
  referenceLinks?: Array<{
    url: string;
    title: string;
    label: string;
    role: string;
    provider: string;
    rankProfile: string;
    source?: string | null;
    usefulness?: number | null;
    subtitle?: string | null;
    priceText?: string | null;
  }>;
  place?: {
    name: string;
    lat: number;
    lng: number;
    category?: string | null;
    address?: string | null;
    roadAddress?: string | null;
    mapUrl?: string | null;
    rating?: number | null;
    ratingCount?: number | null;
    imageUrl?: string | null;
  } | null;
  lifecycleKind: string;
  intentInstances?: Array<{
    intentType: "schedule" | "todo" | "knowledge" | "memo";
    label?: string | null;
    payload?: {
      title?: string | null;
      date?: string | null;
      time?: string | null;
      deadline?: string | null;
    } | null;
  }>;
}

function deriveTitle(item: LiveItemResponse): string {
  const first = item.intentInstances?.[0];
  const raw =
    first?.label ??
    first?.payload?.title ??
    item.text ??
    item.userMemo ??
    item.url ??
    "새 기록";
  const cleaned = raw.replace(/^https?:\/\/(www\.)?/, "").trim();
  return cleaned.length > 28 ? `${cleaned.slice(0, 28)}…` : cleaned;
}

function mapLiveItem(item: LiveItemResponse): AnalyzedItemWire {
  const title = deriveTitle(item);
  const intents: AnalyzedItemWire["intents"] = (item.intentInstances ?? []).map((ii) => ({
    intentType: ii.intentType,
    label: ii.label ?? ii.payload?.title ?? undefined,
    date: ii.payload?.date ?? undefined,
    time: ii.payload?.time ?? undefined,
    deadline: ii.payload?.deadline ?? undefined,
  }));
  if (intents.length === 0) {
    // 분석이 아직/실패 — 기록 자체는 남았다는 정직한 최소 표현
    intents.push({ intentType: "memo", label: title });
  }
  // 분석 실패를 성공처럼 꾸미지 않는다 — 기록은 남았다는 사실만 정직하게
  const fallbackSummary =
    item.lifecycleKind === "failed"
      ? "이번엔 정리에 실패했어요 — 기록 자체는 안전하게 남아 있어요."
      : "맥락 그대로 기록해뒀어요. 정리가 끝나면 더 또렷해져요.";
  return {
    id: item.id,
    title,
    summary: item.summary?.trim() || fallbackSummary,
    category: item.category?.trim() || "새 기록",
    url: item.url ?? undefined,
    text: item.text ?? undefined,
    userMemo: item.userMemo ?? undefined,
    shoppingProductQuery: item.shoppingProductQuery ?? undefined,
    referenceLinks: item.referenceLinks?.map((link) => ({
      url: link.url,
      title: link.title,
      label: link.label,
      role: link.role,
      provider: link.provider,
      rankProfile: link.rankProfile,
      source: link.source ?? undefined,
      usefulness: link.usefulness ?? undefined,
      subtitle: link.subtitle ?? undefined,
      priceText: link.priceText ?? undefined,
    })),
    place: item.place
      ? {
          name: item.place.name,
          lat: item.place.lat,
          lng: item.place.lng,
          category: item.place.category ?? undefined,
          address: item.place.address ?? undefined,
          roadAddress: item.place.roadAddress ?? undefined,
          mapUrl: item.place.mapUrl ?? undefined,
          rating: item.place.rating ?? undefined,
          ratingCount: item.place.ratingCount ?? undefined,
          imageUrl: item.place.imageUrl ?? undefined,
        }
      : undefined,
    intents,
  };
}

function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const t = setTimeout(done, ms);
    function done() {
      clearTimeout(t);
      signal?.removeEventListener("abort", done);
      resolve();
    }
    signal?.addEventListener("abort", done, { once: true });
  });
}

/** 라이브 아이템 재조회 — 분석 완료 전이면 짧게 재시도. 실패·클라 단절 시 null. */
export async function liveItem(
  up: Upstream,
  itemId: string,
  clientSignal?: AbortSignal,
): Promise<AnalyzedItemWire | null> {
  for (let attempt = 0; attempt <= ITEM_POLL_RETRIES; attempt++) {
    if (clientSignal?.aborted) return null;
    try {
      const signals = [AbortSignal.timeout(JSON_TIMEOUT_MS)];
      if (clientSignal) signals.push(clientSignal);
      const res = await fetch(`${up.base}/mochi_items/${itemId}`, {
        headers: { authorization: `Bearer ${up.token}` },
        signal: AbortSignal.any(signals),
        cache: "no-store",
      });
      if (res.status === 404) return null;
      if (res.ok) {
        const item = (await res.json()) as LiveItemResponse;
        const settled =
          item.lifecycleKind === "analyzed" ||
          item.lifecycleKind === "failed" ||
          (item.intentInstances?.length ?? 0) > 0;
        if (settled || attempt === ITEM_POLL_RETRIES) return mapLiveItem(item);
      }
    } catch {
      if (clientSignal?.aborted || attempt === ITEM_POLL_RETRIES) return null;
    }
    await abortableSleep(ITEM_POLL_INTERVAL_MS, clientSignal);
  }
  return null;
}
