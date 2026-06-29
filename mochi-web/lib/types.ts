// UI 도메인 타입 — 백엔드 OpenAPI(schema.ts)를 화면이 쓰기 쉽게 정제한 표현.

export type IntentType = "schedule" | "todo" | "knowledge" | "memo";
export type TintKey = "purple" | "blush" | "mint" | "butter" | "sky" | "peach";
export type CardKind = "screenshot" | "link" | "memo";

export interface SampleCard {
  id: string;
  kind: CardKind;
  title: string;
  oneline: string;
  source?: string;
  /** BFF 프록시 경로(/api/seed/image/…) 또는 정적 경로. 없으면 색 배경 카드. */
  imageUrl?: string;
  intents: IntentType[];
  category?: string;
  tint: TintKey;
  savedAtIso: string;
}

export type RecallReasonKind = "deadline" | "decay" | "similarity";

export interface RecallReason {
  kind: RecallReasonKind;
  /** 사람이 읽는 규칙 칩 라벨 — "왜 지금 떠올랐는지" 증명 (codex ISSUE-7). */
  label: string;
  detail: string;
}

export interface RecallCard extends SampleCard {
  reason: RecallReason;
  daysAgo: number;
}

export interface AnalyzedEntity {
  type: string;
  value: string;
}

/** 라이브 분석 결과 (백엔드 AnalysisResult의 UI 투영). */
export interface AnalysisResult {
  itemId?: string;
  summary: string;
  category?: string;
  needsReview: boolean;
  intents: IntentType[];
  entities: AnalyzedEntity[];
  importance: number;
}

/** SSE 진행 단계. */
export type AnalyzeStage =
  | "ingested"
  | "normalized"
  | "analyzing"
  | "analyzed"
  | "failed";

export const INTENT_LABEL: Record<IntentType, string> = {
  schedule: "일정",
  todo: "할 일",
  knowledge: "지식",
  memo: "기록",
};

export const TINT_HEX: Record<TintKey, { soft: string; strong: string }> = {
  purple: { soft: "#EDE6FF", strong: "#8B6CFF" },
  blush: { soft: "#FFE0E3", strong: "#EF7E91" },
  mint: { soft: "#DFF8EC", strong: "#4CCB8F" },
  butter: { soft: "#FFF7DE", strong: "#E5B435" },
  sky: { soft: "#DDEEFF", strong: "#6BA8FF" },
  peach: { soft: "#FFF5F0", strong: "#FF9B72" },
};
