import { z } from "zod";

/*
 * 페르소나 시드 스키마 — 웹 렌더(정적)와 백엔드 시더(scripts/seed-backend.ts) 겸용.
 * 계약 원천: mochi-backend/openapi.json (ConfirmedInstanceDTO, IngestChannel, IntentPayloadPatchDTO).
 * 시간축은 전부 "오늘 기준 상대값" — MochiItemCreateRequest 에 capturedAt 이 없어
 * 절대 시각은 웹 렌더 시점(seedRuntime)에서만 계산한다.
 */

export const intentTypeSchema = z.enum([
  "schedule",
  "todo",
  "knowledge",
  "memo",
]);

export const channelSchema = z.enum([
  "kakaoTalk",
  "instagram",
  "youtube",
  "safari",
  "screenshot",
  "appIntent",
  "appShareSheet",
  "appDirectInput",
  "chat",
  "appCalendar",
  "unknown",
]);

/** IntentPayloadPatchDTO 의 상대시간 버전 — 렌더/시딩 시점에 절대화 */
export const seedPayloadSchema = z.object({
  title: z.string().optional(),
  /** 일정 시작일 (오늘 + n일, 음수 = 과거) */
  dateInDays: z.number().int().optional(),
  time: z
    .string()
    .regex(/^\d{2}:\d{2}$/)
    .optional(),
  /** 할일 마감 (오늘 + n일) */
  deadlineInDays: z.number().int().optional(),
  person: z.string().optional(),
  topic: z.string().optional(),
  url: z.string().url().optional(),
  note: z.string().optional(),
});

export const seedInstanceSchema = z.object({
  intentType: intentTypeSchema,
  label: z.string().optional(),
  /** 웹 전용 — todo 완료 표시 상태 (백엔드는 lifecycle 전이로 표현) */
  done: z.boolean().optional(),
  payload: seedPayloadSchema.optional(),
});

export const seedImageSchema = z.object({
  file: z.string().startsWith("/seed/caps/"),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
});

/** iOS MochiItemKind 3변형 — 검색 그리드·카드 렌더의 분기 축 */
export const seedKindSchema = z.enum(["screenshot", "url", "memo"]);

export const seedItemSchema = z
  .object({
    slug: z.string().regex(/^[a-z0-9-]+$/),
    kind: seedKindSchema,
    channel: channelSchema,
    /** 표시용 출처 라벨 — "스크린샷" "Safari" "카카오톡" "YouTube" */
    source: z.string(),
    title: z.string(),
    url: z.string().url().optional(),
    /** 원문 텍스트 (memo·url 본문) */
    text: z.string().optional(),
    /** 저장 시 사용자가 덧붙인 메모 */
    userMemo: z.string().optional(),
    /** 스크린샷 OCR 텍스트 — 백엔드 시딩 시 analysisOcrText 로 전달, 검색 근거 */
    ocrText: z.string().optional(),
    /** LLM 자유형 카테고리 (예: "학교·과제") */
    category: z.string(),
    /** "모찌가 정리했어요" 요약 */
    summary: z.string(),
    instances: z.array(seedInstanceSchema).min(1),
    image: seedImageSchema.optional(),
    capturedDaysAgo: z.number().nonnegative(),
    relatedSlugs: z.array(z.string()).optional(),
    favorite: z.boolean().optional(),
  })
  .refine((it) => it.kind !== "screenshot" || it.image, {
    message: "screenshot 카드는 image 필수",
  })
  .refine((it) => it.kind !== "url" || it.url, {
    message: "url 카드는 url 필수",
  });

/** iOS RecallReasonKind 4종 — 라벨·색 매핑은 컴포넌트(ReasonChip)가 소유 */
export const recallKindSchema = z.enum([
  "fadingValue",
  "relatedCluster",
  "revisitedOften",
  "linkedToRecent",
]);

export const seedRecallSchema = z.object({
  itemSlug: z.string(),
  kind: recallKindSchema,
  /** "왜 지금 떠올랐는지" 한 줄 — 확인 질문 톤 (UX_SPEC §3.11) */
  oneline: z.string(),
  /** 카드 아래 요점 1~3개 */
  gist: z.array(z.string()).min(1).max(3),
});

/* ── canned 응답 (폴백 — 라이브와 같은 wire 포맷, P4 에서 소비) ── */

export const chatScriptEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("tool_started"), name: z.string(), label: z.string() }),
  z.object({ type: z.literal("tool_finished"), name: z.string(), summary: z.string() }),
  z.object({ type: z.literal("message_delta"), text: z.string() }),
  z.object({
    type: z.literal("citation"),
    index: z.number().int().positive(),
    itemSlug: z.string(),
  }),
  z.object({
    type: z.literal("proposal"),
    proposalType: z.enum([
      "item_update",
      "item_delete",
      "create_schedule",
      "reminder",
      "create_memo",
    ]),
    payload: z.record(z.string(), z.unknown()),
  }),
]);

export const seedCannedChatSchema = z.object({
  id: z.string(),
  /** 질의 매칭 키워드 (OR, 소문자 비교) */
  triggers: z.array(z.string()).min(1),
  script: z.array(chatScriptEventSchema).min(1),
});

export const seedCannedSearchSchema = z.object({
  id: z.string(),
  triggers: z.array(z.string()).min(1),
  citationSlugs: z.array(z.string()).min(1),
});

export const personaAccentSchema = z.enum([
  "sky",
  "butter",
  "mint",
  "blush",
  "peach",
  "purple",
]);

export const seedPersonaSchema = z.object({
  slug: z.string().regex(/^[a-z]+$/),
  name: z.string(),
  age: z.number().int(),
  job: z.string(),
  /** 페인포인트 한 줄 (선택 카드) — PRODUCT.md §2.1 기반 */
  tagline: z.string(),
  intro: z.string(),
  /** 백엔드 실계정 UUID 를 담는 서버 env 키 이름 */
  uuidEnvKey: z.string().startsWith("MOCHI_PERSONA_UUID_"),
  accent: personaAccentSchema,
  /** 선택 카드의 대표 캡처 3장 */
  heroSlugs: z.array(z.string()).length(3),
  suggestedSearch: z.array(z.string()).min(2),
  suggestedChat: z.array(z.string()).min(2),
  items: z.array(seedItemSchema).min(15),
  recall: z.array(seedRecallSchema).min(3),
  cannedChat: z.array(seedCannedChatSchema).default([]),
  cannedSearch: z.array(seedCannedSearchSchema).default([]),
});

export type IntentType = z.infer<typeof intentTypeSchema>;
export type SeedChannel = z.infer<typeof channelSchema>;
export type SeedPayload = z.infer<typeof seedPayloadSchema>;
export type SeedInstance = z.infer<typeof seedInstanceSchema>;
export type SeedItem = z.infer<typeof seedItemSchema>;
export type RecallKind = z.infer<typeof recallKindSchema>;
export type SeedRecallEntry = z.infer<typeof seedRecallSchema>;
export type ChatScriptEvent = z.infer<typeof chatScriptEventSchema>;
export type SeedCannedChat = z.infer<typeof seedCannedChatSchema>;
export type SeedCannedSearch = z.infer<typeof seedCannedSearchSchema>;
export type PersonaAccent = z.infer<typeof personaAccentSchema>;
export type SeedPersona = z.infer<typeof seedPersonaSchema>;
