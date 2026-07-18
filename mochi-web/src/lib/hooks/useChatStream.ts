"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { AnalyzedItemWire, ChatWireEvent, ProposalType } from "@/lib/api/wire";
import { parseSseStream, toTagged } from "@/lib/sse/parse";
import { recordMode } from "@/lib/liveStats";
import backendIds from "@seed/backend-ids.json";
import { markProposalExperience } from "@/lib/journeySession";

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

export type ProposalStatus =
  | "pending"
  | "confirming"
  | "confirmed"
  | "preview"
  | "failed"
  | "expired"
  | "cancelled";

export interface ChatProposal {
  id: string;
  type: ProposalType;
  payload: Record<string, unknown>;
  status: ProposalStatus;
  error?: string;
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

interface LiveChatContext {
  id: string;
  title: string;
  summary: string;
}

function contextForQuestion(text: string, context?: LiveChatContext): LiveChatContext | undefined {
  if (!context) return undefined;
  const lower = text.toLowerCase();
  if (lower.includes("방금 보낸")) return context;
  const titleTokens = context.title
    .toLowerCase()
    .split(/\s+/)
    .filter((token) => token.length > 1);
  return titleTokens.some((token) => lower.includes(token)) ? context : undefined;
}

export function useChatStream(
  personaSlug: string,
  resolveSlug: (itemId: string) => string | null,
  liveContext?: LiveChatContext,
  onCreatedItem?: (item: AnalyzedItemWire) => void,
) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [streaming, setStreaming] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const messagesRef = useRef<ChatMessage[]>([]);
  // state 클로저보다 빠른 동기 가드 — 같은 프레임 중복 send 방지
  const streamingRef = useRef(false);

  useEffect(() => () => abortRef.current?.abort(), []);
  useEffect(() => {
    messagesRef.current = messages;
  }, [messages]);

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
    async (text: string, options?: { useLiveContext?: boolean }) => {
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
      const relevantContext = options?.useLiveContext
        ? liveContext
        : contextForQuestion(trimmed, liveContext);

      try {
        const res = await fetch(`/api/bff/chat/${conversationId(personaSlug)}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text: trimmed, persona: personaSlug, liveContext: relevantContext }),
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
                    slug: resolveSlug(e.item_id),
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
    [liveContext, personaSlug, patchLast, resolveSlug],
  );

  const setProposalStatus = useCallback(
    (proposalId: string, status: ProposalStatus, error?: string) => {
      setMessages((prev) =>
        prev.map((m) =>
          m.role === "assistant"
            ? {
                ...m,
                proposals: m.proposals.map((p) =>
                  p.id === proposalId ? { ...p, status, error } : p,
                ),
              }
            : m,
        ),
      );
    },
    [],
  );

  /** proposal 확정 — REST/로컬 실행 성공 뒤에만 confirmed 로 바뀐다. */
  const confirmProposal = useCallback(
    async (proposalId: string) => {
      const proposal = messagesRef.current
        .flatMap((message) => (message.role === "assistant" ? message.proposals : []))
        .find((candidate) => candidate.id === proposalId);
      if (!proposal || (proposal.status !== "pending" && proposal.status !== "failed")) return;
      setProposalStatus(proposalId, "confirming");
      try {
        const cid = conversationId(personaSlug);
        const response = await fetch(`/api/bff/chat/${cid}/proposals/${proposalId}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action: "confirm",
            persona: personaSlug,
            type: proposal.type,
            payload: proposal.payload,
          }),
        });
        if (!response.ok) throw new Error(`proposal_http_${response.status}`);
        const result = (await response.json()) as {
          status?: ProposalStatus;
          createdItem?: AnalyzedItemWire;
        };
        if (result.createdItem) onCreatedItem?.(result.createdItem);
        if (result.status === "confirmed" || result.status === "preview") {
          setProposalStatus(proposalId, result.status);
          markProposalExperience(personaSlug, result.status);
        } else if (result.status === "expired") {
          setProposalStatus(proposalId, "expired", "대상 기록이 이미 바뀌었어요.");
        } else {
          setProposalStatus(proposalId, "failed", "잠시 후 다시 시도해주세요.");
        }
      } catch {
        setProposalStatus(proposalId, "failed", "잠시 후 다시 시도해주세요.");
      }
    },
    [onCreatedItem, personaSlug, setProposalStatus],
  );

  const cancelProposal = useCallback(
    (proposalId: string) => {
      const proposal = messagesRef.current
        .flatMap((message) => (message.role === "assistant" ? message.proposals : []))
        .find((candidate) => candidate.id === proposalId);
      setProposalStatus(proposalId, "cancelled");
      if (!proposal) return;
      const cid = conversationId(personaSlug);
      void fetch(`/api/bff/chat/${cid}/proposals/${proposalId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "cancel",
          persona: personaSlug,
          type: proposal.type,
          payload: proposal.payload,
        }),
      });
    },
    [personaSlug, setProposalStatus],
  );

  return { messages, streaming, send, confirmProposal, cancelProposal };
}
