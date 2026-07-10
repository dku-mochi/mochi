"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { ChatWireEvent, ProposalType } from "@/lib/api/wire";
import { parseSseStream, toTagged } from "@/lib/sse/parse";
import { recordMode } from "@/lib/liveStats";
import backendIds from "@seed/backend-ids.json";

/*
 * 채팅 스트림 훅 — POST-as-SSE 소비. 라이브/폴백이 같은 wire 라 이 아래는 단일 경로.
 * conversationId 는 클라 생성(uuid), 스트리밍 중 입력 잠금(동시 run 409 예방).
 */

export interface ToolStep {
  name: string;
  label: string;
  summary?: string;
  done: boolean;
}

export interface ChatCitation {
  index: number;
  itemId: string;
  /** 로컬 시드 slug 로 해석된 id (라이브 uuid ↔ slug 매핑 포함) */
  slug: string | null;
  title: string;
  snippet: string;
}

export type ProposalStatus = "pending" | "confirming" | "confirmed" | "cancelled";

export interface ChatProposal {
  id: string;
  type: ProposalType;
  payload: Record<string, unknown>;
  status: ProposalStatus;
}

export interface AssistantMessage {
  role: "assistant";
  id: string;
  text: string;
  tools: ToolStep[];
  citations: ChatCitation[];
  proposals: ChatProposal[];
  streaming: boolean;
  error?: string;
}

export interface UserMessage {
  role: "user";
  id: string;
  text: string;
}

export type ChatMessage = UserMessage | AssistantMessage;

/** 라이브 uuid → 시드 slug (P7 시더 산출물). 폴백은 slug 를 그대로 쓴다. */
const UUID_TO_SLUG: Record<string, string> = backendIds as Record<string, string>;

export function resolveItemSlug(itemId: string, knownSlugs: Set<string>): string | null {
  if (knownSlugs.has(itemId)) return itemId;
  return UUID_TO_SLUG[itemId] ?? null;
}

let seq = 0;
const nextId = () => `m${++seq}_${Date.now().toString(36)}`;

function conversationId(persona: string): string {
  const key = `mochi-conv-${persona}`;
  let id = sessionStorage.getItem(key);
  if (!id) {
    id = crypto.randomUUID();
    sessionStorage.setItem(key, id);
  }
  return id;
}

export function useChatStream(personaSlug: string, knownSlugs: Set<string>) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [streaming, setStreaming] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  // state 클로저보다 빠른 동기 가드 — 같은 프레임 중복 send 방지
  const streamingRef = useRef(false);

  useEffect(() => () => abortRef.current?.abort(), []);

  const patchLast = useCallback(
    (fn: (m: AssistantMessage) => AssistantMessage) => {
      setMessages((prev) => {
        const last = prev[prev.length - 1];
        if (!last || last.role !== "assistant") return prev;
        return [...prev.slice(0, -1), fn(last)];
      });
    },
    [],
  );

  const send = useCallback(
    async (text: string) => {
      const trimmed = text.trim();
      if (!trimmed || streamingRef.current) return;

      streamingRef.current = true;
      setStreaming(true);
      setMessages((prev) => [
        ...prev,
        { role: "user", id: nextId(), text: trimmed },
        {
          role: "assistant",
          id: nextId(),
          text: "",
          tools: [],
          citations: [],
          proposals: [],
          streaming: true,
        },
      ]);

      const ac = new AbortController();
      abortRef.current = ac;

      try {
        const res = await fetch(`/api/bff/chat/${conversationId(personaSlug)}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text: trimmed, persona: personaSlug }),
          signal: ac.signal,
        });
        if (!res.ok || !res.body) throw new Error(`chat_http_${res.status}`);
        recordMode(res.headers.get("x-mochi-mode"));

        for await (const raw of parseSseStream(res.body, ac.signal)) {
          const e = toTagged<ChatWireEvent>(raw);
          if (!e) continue;
          switch (e.kind) {
            case "tool_started":
              patchLast((m) => ({
                ...m,
                tools: [...m.tools, { name: e.name, label: e.label, done: false }],
              }));
              break;
            case "tool_finished":
              patchLast((m) => ({
                ...m,
                tools: m.tools.map((t) =>
                  t.name === e.name && !t.done
                    ? { ...t, summary: e.summary, done: true }
                    : t,
                ),
              }));
              break;
            case "message_delta":
              patchLast((m) => ({ ...m, text: m.text + e.text }));
              break;
            case "citation":
              patchLast((m) => ({
                ...m,
                citations: [
                  ...m.citations,
                  {
                    index: e.index,
                    itemId: e.item_id,
                    slug: resolveItemSlug(e.item_id, knownSlugs),
                    title: e.title,
                    snippet: e.snippet,
                  },
                ],
              }));
              break;
            case "proposal":
              patchLast((m) => ({
                ...m,
                proposals: [
                  ...m.proposals,
                  { id: e.id, type: e.type, payload: e.payload, status: "pending" },
                ],
              }));
              break;
            case "error":
              patchLast((m) => ({ ...m, error: e.message, streaming: false }));
              break;
            case "done":
              patchLast((m) => ({ ...m, streaming: false }));
              break;
          }
        }
        // 스트림이 done 없이 끊겨도 완결 표시
        patchLast((m) => (m.streaming ? { ...m, streaming: false } : m));
      } catch (err) {
        if ((err as Error).name !== "AbortError") {
          patchLast((m) => ({
            ...m,
            streaming: false,
            error: "연결이 고르지 않아요. 다시 물어봐 주세요.",
          }));
        }
      } finally {
        streamingRef.current = false;
        setStreaming(false);
        abortRef.current = null;
      }
    },
    [personaSlug, patchLast, knownSlugs],
  );

  const setProposalStatus = useCallback(
    (proposalId: string, status: ProposalStatus) => {
      setMessages((prev) =>
        prev.map((m) =>
          m.role === "assistant"
            ? {
                ...m,
                proposals: m.proposals.map((p) =>
                  p.id === proposalId ? { ...p, status } : p,
                ),
              }
            : m,
        ),
      );
    },
    [],
  );

  /** proposal 확정 — pending → confirming → confirmed (LLM 은 read-only, 확정 탭이 유일한 쓰기) */
  const confirmProposal = useCallback(
    (proposalId: string) => {
      setProposalStatus(proposalId, "confirming");
      setTimeout(() => setProposalStatus(proposalId, "confirmed"), 750);
    },
    [setProposalStatus],
  );

  const cancelProposal = useCallback(
    (proposalId: string) => setProposalStatus(proposalId, "cancelled"),
    [setProposalStatus],
  );

  return { messages, streaming, send, confirmProposal, cancelProposal };
}
