import "server-only";

import type { SeedCannedChat, SeedPersona } from "@seed/schema";
import { getPersona } from "@seed/index";
import type { AnalyzedItemWire, SearchWireResponse } from "@/lib/api/wire";
import { chunkText, type OutEvent } from "./sse";

/*
 * 폴백 엔진 — 라이브 백엔드 없이도 같은 wire 포맷으로 완결.
 * 규약: 클라이언트는 라이브/폴백을 구분하지 않는다 (README 폴백 규약 계승).
 */

/* ── 채팅 ─────────────────────────────── */

function score(triggers: string[], text: string): number {
  const t = text.toLowerCase();
  return triggers.reduce((n, k) => (t.includes(k.toLowerCase()) ? n + 1 : n), 0);
}

export function pickCannedChat(
  persona: SeedPersona,
  text: string,
): SeedCannedChat | null {
  let best: SeedCannedChat | null = null;
  let bestScore = 0;
  for (const c of persona.cannedChat) {
    const s = score(c.triggers, text);
    if (s > bestScore) {
      best = c;
      bestScore = s;
    }
  }
  return best;
}

export interface ChatLiveContext {
  id: string;
  title: string;
  summary: string;
}

function rid() {
  return `fb_${Math.random().toString(36).slice(2, 10)}`;
}

export function chatWireEvents(
  personaSlug: string,
  text: string,
  liveContext?: ChatLiveContext,
): OutEvent[] {
  const persona = getPersona(personaSlug);
  const run_id = rid();
  const out: OutEvent[] = [];

  const canned = persona ? pickCannedChat(persona, text) : null;

  if (persona && liveContext) {
    out.push({
      event: "tool_started",
      data: { run_id, name: "search_items", label: "관련 기록을 찾고 있어요…" },
      delayMs: 250,
    });
    out.push({
      event: "tool_finished",
      data: { run_id, name: "search_items", summary: `‘${liveContext.title}’ 확인` },
      delayMs: 850,
    });
    const msg = `저장해둔 **${liveContext.title}** 기록을 기준으로 보면, ${liveContext.summary}`;
    for (const chunk of chunkText(msg)) {
      out.push({ event: "message_delta", data: { run_id, text: chunk }, delayMs: 22 });
    }
    out.push({
      event: "citation",
      data: {
        run_id,
        index: 1,
        item_id: liveContext.id,
        title: liveContext.title,
        snippet: liveContext.summary,
      },
      delayMs: 160,
    });
    out.push({ event: "done", data: { run_id, message_id: rid() }, delayMs: 150 });
    return out;
  }

  if (!persona || !canned) {
    // 정직한 무매칭 응답 — 추천 질문으로 유도
    out.push({
      event: "tool_started",
      data: { run_id, name: "search_items", label: "기록을 뒤지고 있어요…" },
      delayMs: 250,
    });
    out.push({
      event: "tool_finished",
      data: { run_id, name: "search_items", summary: "딱 맞는 기록을 찾지 못함" },
      delayMs: 1100,
    });
    const msg =
      "질문과 딱 맞는 기록을 찾지 못했어요. 아래 추천 질문으로 시작하거나, 기록에 있을 법한 단어로 다시 물어봐 주세요.";
    for (const chunk of chunkText(msg)) {
      out.push({ event: "message_delta", data: { run_id, text: chunk }, delayMs: 22 });
    }
    out.push({
      event: "done",
      data: { run_id, message_id: rid() },
      delayMs: 150,
    });
    return out;
  }

  let proposalSeq = 0;
  for (const e of canned.script) {
    switch (e.type) {
      case "tool_started":
        out.push({
          event: "tool_started",
          data: { run_id, name: e.name, label: e.label },
          delayMs: 250,
        });
        break;
      case "tool_finished":
        out.push({
          event: "tool_finished",
          data: { run_id, name: e.name, summary: e.summary },
          delayMs: 1200,
        });
        break;
      case "message_delta": {
        let first = true;
        for (const chunk of chunkText(e.text)) {
          out.push({
            event: "message_delta",
            data: { run_id, text: chunk },
            delayMs: first ? 500 : 22,
          });
          first = false;
        }
        break;
      }
      case "citation": {
        const item = persona.items.find((i) => i.slug === e.itemSlug);
        out.push({
          event: "citation",
          data: {
            run_id,
            index: e.index,
            item_id: e.itemSlug,
            title: item?.title ?? e.itemSlug,
            snippet: item?.summary ?? "",
          },
          delayMs: 160,
        });
        break;
      }
      case "proposal":
        out.push({
          event: "proposal",
          data: {
            run_id,
            id: `fbp_${++proposalSeq}_${run_id}`,
            type: e.proposalType,
            payload: e.payload,
          },
          delayMs: 420,
        });
        break;
    }
  }
  out.push({ event: "done", data: { run_id, message_id: rid() }, delayMs: 150 });
  return out;
}

/* ── 검색 ─────────────────────────────── */

export function searchFallback(
  personaSlug: string,
  query: string,
  liveContext?: ChatLiveContext,
): SearchWireResponse {
  const persona = getPersona(personaSlug);
  if (!persona) return { citations: [] };

  // 추천 검색은 이 탭에서 방금 만든 기록을 가리킨다. 실검색 불가 시에도
  // 공유 페르소나 시드가 아니라 현재 방문자의 세션 기록으로 정직하게 강등한다.
  if (liveContext) {
    return {
      citations: [{ mochiItemId: liveContext.id, snippet: liveContext.summary, score: 1 }],
    };
  }

  let best = null as null | (typeof persona.cannedSearch)[number];
  let bestScore = 0;
  for (const c of persona.cannedSearch) {
    const s = score(c.triggers, query);
    if (s > bestScore) {
      best = c;
      bestScore = s;
    }
  }
  if (best) {
    return {
      citations: best.citationSlugs.map((slug, i) => ({
        mochiItemId: slug,
        snippet: persona.items.find((it) => it.slug === slug)?.summary ?? "",
        score: 0.95 - i * 0.07,
      })),
    };
  }

  // 무매칭 — 시드 전체에 대한 단순 토큰 매칭으로 정직하게
  const tokens = query.toLowerCase().split(/\s+/).filter((t) => t.length > 1);
  const hits = persona.items
    .map((item) => {
      const hay =
        `${item.title} ${item.summary} ${item.category} ${item.ocrText ?? ""} ${item.text ?? ""}`.toLowerCase();
      const s = tokens.reduce((n, t) => (hay.includes(t) ? n + 1 : n), 0);
      return { slug: item.slug, s };
    })
    .filter((h) => h.s > 0)
    .sort((a, b) => b.s - a.s)
    .slice(0, 6);

  return {
    citations: hits.map((h, i) => ({ mochiItemId: h.slug, snippet: "", score: 0.8 - i * 0.08 })),
  };
}

/* ── 라이브 분석 (S2) ─────────────────────────────── */

export interface IngestInput {
  text?: string;
  url?: string;
  memo?: string;
}

export function encodeFallbackId(input: IngestInput): string {
  // id 는 URL path 에 실린다 — 휴리스틱 분석은 앞부분이면 충분하니 인코딩 전에 자른다
  // (원문 전체는 클라이언트 세션 오버레이가 갖고 있다)
  const json = JSON.stringify({
    ...input,
    text: input.text?.slice(0, 400),
    memo: input.memo?.slice(0, 200),
  });
  return `fb.${Buffer.from(json, "utf8").toString("base64url")}`;
}

// encode 자체 상한(400+500+200자, 한글 3바이트) 기준 여유 상한 — 초과분은 위조 id
const MAX_FALLBACK_ID_LENGTH = 8192;

export function decodeFallbackId(id: string): IngestInput | null {
  if (!id.startsWith("fb.") || id.length > MAX_FALLBACK_ID_LENGTH) return null;
  try {
    return JSON.parse(Buffer.from(id.slice(3), "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

export function analysisWireEvents(): OutEvent[] {
  return [
    { event: "node", data: { lifecycle_kind: "ingested" }, delayMs: 350 },
    { event: "node", data: { lifecycle_kind: "normalized" }, delayMs: 800 },
    { event: "node", data: { lifecycle_kind: "analyzing" }, delayMs: 1100 },
    { event: "final", data: { lifecycle_kind: "analyzed" }, delayMs: 1400 },
  ];
}

const DAY = 86_400_000;

function kstDateStr(daysFromNow: number): string {
  const d = new Date(Date.now() + 9 * 3_600_000 + daysFromNow * DAY);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

/**
 * 결정론적 휴리스틱 분석 — 폴백에서 입력만으로 그럴듯한 결과를 만든다.
 * (라이브 모드에서는 실백엔드 Gemini 분석이 이 자리를 대신한다)
 */
export function analyzeHeuristic(input: IngestInput): AnalyzedItemWire {
  const raw = [input.text, input.url, input.memo].filter(Boolean).join(" ");
  const title =
    (input.text ?? input.memo ?? input.url ?? "새 기록")
      .replace(/^https?:\/\/(www\.)?/, "")
      .slice(0, 28)
      .trim() + ((input.text?.length ?? 0) > 28 ? "…" : "");

  const intents: AnalyzedItemWire["intents"] = [];

  const dayMatch = raw.match(/(오늘|내일|모레|이번 ?주|다음 ?주|금요일|토요일|일요일)/);
  const timeMatch = raw.match(/(\d{1,2})시/);
  // "3시"는 일상어로 오후 — 9시 미만은 PM 으로 해석
  const hour = timeMatch
    ? (() => {
        const h = Number(timeMatch[1]);
        return h < 9 ? h + 12 : h;
      })()
    : null;
  const relDays: Record<string, number> = {
    오늘: 0,
    내일: 1,
    모레: 2,
    "이번주": 4,
    "이번 주": 4,
    "다음주": 8,
    "다음 주": 8,
    금요일: 3,
    토요일: 4,
    일요일: 5,
  };

  const todoLike = /(하기|해야|제출|숙제|과제|리뷰|신청|예약|보내|사기|정리)/.test(raw);
  const scheduleLike = dayMatch !== null && /(회의|약속|발표|미팅|모임|생일|공연|수업)/.test(raw);

  if (scheduleLike) {
    intents.push({
      intentType: "schedule",
      label: title,
      date: kstDateStr(relDays[dayMatch![1].replace(" ", "")] ?? 3),
      time: hour !== null ? `${String(hour).padStart(2, "0")}:00` : undefined,
    });
  }
  if (todoLike) {
    intents.push({
      intentType: "todo",
      label: title,
      deadline: dayMatch ? kstDateStr(relDays[dayMatch[1].replace(" ", "")] ?? 5) : undefined,
    });
  }
  if (input.url && !scheduleLike && !todoLike) {
    intents.push({ intentType: "knowledge", label: title });
  }
  if (intents.length === 0) {
    intents.push({ intentType: "memo", label: title });
  }

  const category = input.url
    ? "웹 저장"
    : scheduleLike
      ? "일정"
      : todoLike
        ? "할 일"
        : "메모";

  const toKorean = (iso?: string | null) => {
    if (!iso) return "";
    const [, m, d] = iso.split("-").map(Number);
    return `${m}월 ${d}일`;
  };

  const primary = intents[0].intentType;
  const summaryByIntent: Record<string, string> = {
    schedule: `일정으로 정리했어요. ${toKorean(intents[0].date)}${intents[0].time ? ` ${intents[0].time}` : ""}, 캘린더에 올려뒀어요.`,
    todo: `할 일로 정리했어요${intents.find((i) => i.deadline)?.deadline ? `, 마감은 ${toKorean(intents.find((i) => i.deadline)!.deadline)}` : ""}. 체크리스트에서 완료할 수 있어요.`,
    knowledge: "다시 참고할 지식으로 보관했어요. 나중에 기억나는 대로 검색하면 떠올라요.",
    memo: "맥락 그대로 기록해뒀어요. 타임라인에서 다시 만날 수 있어요.",
  };

  return {
    id: encodeFallbackId(input),
    title,
    summary: summaryByIntent[primary],
    category,
    url: input.url,
    text: input.text,
    userMemo: input.memo,
    intents,
  };
}
