/*
 * 백엔드 SSE wire 계약 — 정본: mochi-backend openapi.json.
 * 라이브 프록시와 폴백이 완전히 같은 포맷을 쓴다 (클라이언트는 모드를 모른다).
 */

export type ProposalType =
  | "item_update"
  | "item_delete"
  | "create_schedule"
  | "reminder"
  | "create_memo";

/** POST /conversations/{id}/messages 스트림 이벤트 */
export type ChatWireEvent =
  | { kind: "message_delta"; run_id: string; text: string }
  | { kind: "tool_started"; run_id: string; name: string; label: string }
  | { kind: "tool_finished"; run_id: string; name: string; summary: string }
  | {
      kind: "citation";
      run_id: string;
      index: number;
      item_id: string;
      title: string;
      snippet: string;
    }
  | {
      kind: "proposal";
      run_id: string;
      id: string;
      type: ProposalType;
      payload: Record<string, unknown>;
    }
  | { kind: "done"; run_id: string; message_id: string }
  | { kind: "error"; run_id: string; code?: string; message: string };

/** GET /mochi_items/{id}/stream 분석 진행 이벤트 */
export type AnalysisWireEvent =
  | { kind: "node"; lifecycle_kind: string }
  | { kind: "final"; lifecycle_kind: string }
  | { kind: "failed"; message: string };

/** POST /search 응답 (필요 필드만 — CitationDTO 는 mochiItemId 케이싱) */
export interface SearchWireResponse {
  answer: string;
  citations: Array<{ mochiItemId: string; snippet?: string; score: number }>;
}

/** 폴백/라이브 공용 — 분석 완료 후 조회되는 아이템 요약 */
export interface AnalyzedItemWire {
  id: string;
  title: string;
  summary: string;
  category: string;
  intents: Array<{
    intentType: "schedule" | "todo" | "knowledge" | "memo";
    label?: string;
    date?: string;
    time?: string;
    deadline?: string;
  }>;
}
