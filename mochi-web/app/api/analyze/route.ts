import { ingest, streamItem, getItem } from "@/lib/api/backend";
import { serverEnv, limits } from "@/lib/env";
import { checkRate } from "@/lib/ratelimit";
import type { AnalysisResult, AnalyzeStage, IntentType } from "@/lib/types";
import type { components } from "@/lib/api/schema";

type MochiItemResponse = components["schemas"]["MochiItemResponse"];

export const dynamic = "force-dynamic";

// ─────────────────────────────────────────────────────────────
// POST /api/analyze — 캡처 입력을 받아 분석 진행을 SSE로 흘린다.
//
// 클라(LiveProof) 합의 포맷: 'data: ' + JSON({ stage, result?, error? }) + '\n\n'
//
// 라이브(serverEnv.liveEnabled): ingest() → id → 백엔드 SSE(streamItem)를 읽어
//   클라 포맷으로 변환한다. 백엔드는 'event: node/final, data:{lifecycle_kind}' 만 주고
//   분석 본문(summary/intents)은 stream에 없으므로, analyzed 시점에 getItem(id)로
//   결과를 조회해 result로 동봉한다.
// 폴백(liveEnabled=false 또는 백엔드 실패): 입력 기반 그럴듯한 결과로 가짜 SSE.
// ─────────────────────────────────────────────────────────────

interface AnalyzeBody {
  channel?: string;
  text?: string;
  url?: string;
  imageRefs?: string[];
}

const encoder = new TextEncoder();

function sse(payload: { stage: AnalyzeStage; result?: AnalysisResult; error?: string }): Uint8Array {
  return encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
}

const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache, no-transform",
  Connection: "keep-alive",
} as const;

export async function POST(req: Request) {
  let body: AnalyzeBody;
  try {
    body = (await req.json()) as AnalyzeBody;
  } catch {
    return Response.json({ error: "본문을 읽을 수 없어요." }, { status: 400 });
  }

  const text = typeof body.text === "string" ? body.text.trim() : undefined;
  const url = typeof body.url === "string" ? body.url.trim() : undefined;
  const imageRefs = Array.isArray(body.imageRefs) ? body.imageRefs.filter((r) => typeof r === "string") : undefined;
  const channel = typeof body.channel === "string" && body.channel ? body.channel : "appDirectInput";

  // ── 검증 ────────────────────────────────────────────────
  if (text && text.length > limits.textMaxLen) {
    return Response.json({ error: `텍스트는 ${limits.textMaxLen}자까지 담을 수 있어요.` }, { status: 400 });
  }
  if (url && !/^https?:\/\//i.test(url)) {
    return Response.json({ error: "링크는 http(s) 주소만 받아요." }, { status: 400 });
  }
  if (!text && !url && !(imageRefs && imageRefs.length > 0)) {
    return Response.json({ error: "담을 내용을 입력해 주세요." }, { status: 400 });
  }

  // ── rate-limit ────────────────────────────────────────────
  const fwd = req.headers.get("x-forwarded-for");
  const rateKey = fwd ? fwd.split(",")[0].trim() : "demo";
  const rate = checkRate(rateKey, serverEnv.ingestPerMinute);
  if (!rate.ok) {
    return Response.json(
      { error: "잠깐만요, 너무 빨라요. 잠시 후 다시 시도해 주세요." },
      { status: 429, headers: { "Retry-After": String(rate.retryAfterSec ?? 10) } },
    );
  }

  // ── 라이브 프록시 (백엔드 SSE → 클라 포맷 변환) ────────────────
  if (serverEnv.liveEnabled) {
    try {
      const ingestRes = await ingest({ channel, text, url, imageRefs });
      if (ingestRes.ok) {
        const data = (await ingestRes.json()) as { id?: string; itemId?: string };
        const id = data.id ?? data.itemId;
        if (id) {
          const upstream = await streamItem(id);
          if (upstream.ok && upstream.body) {
            return new Response(liveTransformStream(upstream.body, id), { headers: SSE_HEADERS });
          }
        }
      }
    } catch {
      /* fall through to fallback */
    }
  }

  // ── graceful 폴백 ─────────────────────────────────────────
  return new Response(fakeAnalyzeStream({ text, url }), { headers: SSE_HEADERS });
}

// ── 백엔드 MochiItemResponse → UI AnalysisResult ───────────────
function mapResult(item: MochiItemResponse): AnalysisResult {
  const instances = item.intentInstances ?? [];
  const intents = Array.from(new Set(instances.map((i) => i.intentType as IntentType)));

  const entities: AnalysisResult["entities"] = [];
  for (const inst of instances) {
    const p = inst.payload;
    if (!p) continue;
    if (p.deadline) entities.push({ type: "마감", value: String(p.deadline) });
    else if (p.date) entities.push({ type: "날짜", value: `${p.date}${p.time ? ` ${p.time}` : ""}` });
    if (p.person) entities.push({ type: "사람", value: String(p.person) });
  }
  for (const link of item.referenceLinks ?? []) {
    const l = link as { url?: string | null; title?: string | null };
    if (l.url) entities.push({ type: "링크", value: l.title || l.url });
  }
  if (item.shoppingProductQuery) entities.push({ type: "상품", value: item.shoppingProductQuery });

  return {
    itemId: item.id,
    summary: item.summary ?? "",
    category: item.category ?? undefined,
    needsReview: item.needsReview,
    intents: intents.length ? intents : ["memo"],
    entities,
    importance: item.importance,
  };
}

function parseSseBlock(block: string): { event?: string; data?: string } {
  let event: string | undefined;
  const dataLines: string[] = [];
  for (const line of block.split("\n")) {
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
  }
  return { event, data: dataLines.length ? dataLines.join("\n") : undefined };
}

const KNOWN_STAGES: AnalyzeStage[] = ["ingested", "normalized", "analyzing", "analyzed", "failed"];

// 백엔드 SSE(event: node/final, data:{lifecycle_kind})를 클라 포맷({stage, result?})으로 변환.
function liveTransformStream(upstream: ReadableStream<Uint8Array>, id: string): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const reader = upstream.getReader();
  let buf = "";
  let resultSent = false;

  async function emitResult(controller: ReadableStreamDefaultController<Uint8Array>) {
    let result: AnalysisResult | undefined;
    try {
      const r = await getItem(id);
      if (r.ok) result = mapResult((await r.json()) as MochiItemResponse);
    } catch {
      /* result stays undefined → 클라가 stage만으로 마무리 */
    }
    controller.enqueue(sse({ stage: "analyzed", result }));
    resultSent = true;
  }

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { value, done } = await reader.read();
      if (done) {
        if (!resultSent) await emitResult(controller);
        controller.close();
        return;
      }
      buf += decoder.decode(value, { stream: true });
      const blocks = buf.split("\n\n");
      buf = blocks.pop() ?? "";
      for (const block of blocks) {
        const { event, data } = parseSseBlock(block);
        if (!data) continue;
        let payload: { lifecycle_kind?: string; lifecycleKind?: string };
        try {
          payload = JSON.parse(data);
        } catch {
          continue;
        }
        const kind = payload.lifecycle_kind ?? payload.lifecycleKind;
        if (event === "failed" || kind === "failed") {
          controller.enqueue(sse({ stage: "failed", error: "분석에 실패했어요. 잠시 후 다시 시도해 주세요." }));
          continue;
        }
        if (kind === "analyzed" || event === "final") {
          if (!resultSent) await emitResult(controller);
          continue;
        }
        if (kind) {
          const stage = (KNOWN_STAGES.includes(kind as AnalyzeStage) ? kind : "analyzing") as AnalyzeStage;
          controller.enqueue(sse({ stage }));
        }
      }
    },
    cancel() {
      reader.cancel().catch(() => {});
    },
  });
}

// ── graceful 폴백: 입력 기반 가짜 SSE ─────────────────────────
function inferResult(input: { text?: string; url?: string }): AnalysisResult {
  const raw = (input.text ?? input.url ?? "").trim();

  const intents: IntentType[] = [];
  const hasDate = /(\d{1,2}\s*[/월.\-]\s*\d{1,2})|(\d{1,2}:\d{2})|오늘|내일|모레|마감|기한|까지|약속|예약|일정/.test(raw);
  const hasTodo = /해야|준비|신청|결제|납부|제출|예매|챙기|todo|확인|구매|사야/.test(raw);
  const isLink = !!input.url || /^https?:\/\//i.test(raw);

  if (hasDate) intents.push("schedule");
  if (hasTodo) intents.push("todo");
  if (isLink || /정리|개념|원리|방법|동작|문서|아티클|블로그/.test(raw)) {
    if (!intents.includes("knowledge")) intents.push("knowledge");
  }
  if (intents.length === 0) intents.push("memo");

  const entities: AnalysisResult["entities"] = [];
  const dateMatch = raw.match(/\d{1,2}\s*[/월.\-]\s*\d{1,2}/);
  if (dateMatch) entities.push({ type: "날짜", value: dateMatch[0].replace(/\s+/g, "") });
  const timeMatch = raw.match(/\d{1,2}:\d{2}/);
  if (timeMatch) entities.push({ type: "시간", value: timeMatch[0] });
  if (input.url) {
    try {
      entities.push({ type: "링크", value: new URL(input.url).hostname.replace(/^www\./, "") });
    } catch {
      /* skip */
    }
  }

  const summary = raw.length > 60 ? `${raw.slice(0, 57)}…` : raw || "담은 내용을 정리했어요.";
  const category = hasDate ? "일정" : hasTodo ? "할 일" : isLink ? "지식" : "기록";
  const importance = hasDate || hasTodo ? 4 : 2;
  const needsReview = intents.length > 1;

  return { summary, category, needsReview, intents, entities, importance };
}

function fakeAnalyzeStream(input: { text?: string; url?: string }): ReadableStream<Uint8Array> {
  const result = inferResult(input);
  const steps: { delay: number; payload: Parameters<typeof sse>[0] }[] = [
    { delay: 0, payload: { stage: "ingested" } },
    { delay: 400, payload: { stage: "normalized" } },
    { delay: 550, payload: { stage: "analyzing" } },
    { delay: 950, payload: { stage: "analyzed", result } },
  ];
  return new ReadableStream<Uint8Array>({
    start(controller) {
      let i = 0;
      const tick = () => {
        if (i >= steps.length) {
          controller.close();
          return;
        }
        controller.enqueue(sse(steps[i].payload));
        i += 1;
        if (i < steps.length) setTimeout(tick, steps[i].delay);
        else controller.close();
      };
      tick();
    },
  });
}
