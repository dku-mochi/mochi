"use client";

import Image from "next/image";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ArrowUp, Sparkles } from "lucide-react";
import { BorderBeam } from "border-beam";
import { usePersona } from "@/components/journey/PersonaProvider";
import { resolveItemSlug, useChatStream } from "@/lib/hooks/useChatStream";
import { makeLiveEntry } from "@/lib/liveOverlay";
import { markJourneyStep } from "@/lib/journeySession";
import { retrievalSuggestionsFor } from "@/lib/retrievalSuggestions";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ChatBubble } from "./ChatBubble";
import { cn } from "@/lib/cn";

/*
 * S5 질문 씬 — 자연어로 기억을 꺼낸다.
 * 증명: 근거 인용(citation) + 쓰기는 proposal 확정으로만 (신뢰 가능한 에이전트).
 */
export function ChatScene({ initialQuery }: { initialQuery?: string }) {
  const { persona, items, liveItems, liveIdToSlug, addLiveCapture } = usePersona();
  const knownSlugs = useMemo(() => new Set(items.map((i) => i.slug)), [items]);
  const resolveSlug = useCallback(
    (id: string) => resolveItemSlug(id, knownSlugs) ?? liveIdToSlug.get(id) ?? null,
    [knownSlugs, liveIdToSlug],
  );
  const latest = liveItems[0];
  const liveContext = useMemo(() => {
    if (!latest) return undefined;
    const id = [...liveIdToSlug].find(([, slug]) => slug === latest.slug)?.[0];
    if (!id) return undefined;
    const place = latest.place
      ? `장소: ${latest.place.name}${latest.place.roadAddress ? ` (${latest.place.roadAddress})` : ""}.`
      : "";
    return {
      id,
      title: latest.title,
      summary: [latest.summary, place].filter(Boolean).join(" "),
    };
  }, [latest, liveIdToSlug]);
  const addProposalItem = useCallback(
    (item: Parameters<typeof makeLiveEntry>[0]) => {
      addLiveCapture(makeLiveEntry(item, { kind: "memo", text: item.text }));
    },
    [addLiveCapture],
  );
  const { messages, streaming, send, confirmProposal, cancelProposal } =
    useChatStream(persona.slug, resolveSlug, liveContext, addProposalItem);
  const [input, setInput] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);
  const autoSent = useRef(false);
  const recentRetrieval = useMemo(
    () => (latest ? retrievalSuggestionsFor(latest).chat : null),
    [latest],
  );
  const suggestions = useMemo(
    () => [
      ...(recentRetrieval
        ? [{ ...recentRetrieval, recent: true }]
        : []),
      ...persona.suggestedChat.map((text) => ({ text, label: text, recent: false })),
    ],
    [recentRetrieval, persona.suggestedChat],
  );

  // 검색 빈 결과 → "모찌에게 물어보기" 위임 (?q=)
  useEffect(() => {
    if (initialQuery && !autoSent.current) {
      autoSent.current = true;
      void send(initialQuery);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialQuery]);

  // 스트리밍 따라가기 — 새 내용이 생기면 바닥으로
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  }, [messages]);

  useEffect(() => {
    const answered = messages.some(
      (message) => message.role === "assistant" && !message.streaming && !message.error,
    );
    if (answered) markJourneyStep(persona.slug, "chat");
  }, [messages, persona.slug]);

  const submit = (text: string, recent = false) => {
    if (!text.trim() || streaming) return;
    setInput("");
    void send(text, { useLiveContext: recent });
  };

  const empty = messages.length === 0;

  return (
    <main className="mx-auto flex h-[calc(100dvh-57px)] min-h-[540px] max-w-3xl flex-col px-5">
      <div
        ref={scrollRef}
        className="min-h-0 flex-1 overflow-y-auto py-6"
        aria-live="polite"
      >
        {empty ? (
          <div className="flex h-full flex-col items-center justify-center text-center">
            <RiseIn index={0}>
              <div className="relative">
                <div
                  className="absolute left-1/2 top-1/2 size-52 -translate-x-1/2 -translate-y-1/2 rounded-full bg-glow/20 blur-3xl"
                  aria-hidden
                />
                <Image
                  src="/brand/mochi-chat.png"
                  alt=""
                  width={88}
                  height={88}
                  className="relative mx-auto h-[76px] w-auto"
                  priority
                />
              </div>
            </RiseIn>
            <RiseIn index={1}>
              <h1 className="mt-4 font-display text-[24px] tracking-head">
                무엇이든 물어보세요
              </h1>
              <p className="mt-2 text-[14px] text-ink-500">
                추천으로 시작하거나 자유롭게 물어보세요. 기록을 근거와 함께 꺼내드려요
              </p>
            </RiseIn>
            <RiseIn index={2} className="mt-6 flex flex-wrap justify-center gap-2">
              {suggestions.map((suggestion) => (
                <button
                  key={`${suggestion.recent ? "recent" : "seed"}-${suggestion.text}`}
                  onClick={() => submit(suggestion.text, suggestion.recent)}
                  className={cn(
                    "inline-flex max-w-full items-center gap-1.5 rounded-full border px-4 py-2.5 text-center text-[13.5px] font-semibold leading-snug transition-[background-color,border-color,transform] active:scale-[0.97]",
                    suggestion.recent
                      ? "border-purple-300 bg-purple-600 text-white shadow-card hover:bg-purple-500"
                      : "border-purple-100 bg-purple-50 text-purple-600 hover:border-purple-200 hover:bg-purple-100",
                  )}
                >
                  {suggestion.recent && <Sparkles className="size-3.5 flex-none" aria-hidden />}
                  <span className="min-w-0 whitespace-normal">{suggestion.label}</span>
                </button>
              ))}
            </RiseIn>
          </div>
        ) : (
          <div className="space-y-4">
            {messages.map((m) => (
              <ChatBubble
                key={m.id}
                message={m}
                onConfirmProposal={confirmProposal}
                onCancelProposal={cancelProposal}
              />
            ))}
          </div>
        )}
      </div>

      <div className="pb-6 pt-2">
        {!empty && (
          <div className="-mx-1 mb-2.5 flex gap-2 overflow-x-auto px-1">
            {suggestions.map((suggestion) => (
              <button
                key={`${suggestion.recent ? "recent" : "seed"}-${suggestion.text}`}
                onClick={() => submit(suggestion.text, suggestion.recent)}
                disabled={streaming}
                className={cn(
                  "flex-none whitespace-nowrap rounded-full border px-3.5 py-1.5 text-[12.5px] font-semibold transition-colors disabled:opacity-50",
                  suggestion.recent
                    ? "border-purple-200 bg-purple-50 text-purple-600"
                    : "border-ink-100 bg-surface text-ink-500 hover:text-purple-600",
                )}
              >
                {suggestion.label}
              </button>
            ))}
          </div>
        )}
        {/* hueRange 기본 30 은 ocean 블루를 초록까지 회전시킨다 — 브랜드 퍼플-블루 안에 묶는다 */}
        <BorderBeam size="pulse-outside" colorVariant="ocean" theme="light" borderRadius={22} hueRange={10}>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            submit(input);
          }}
          className="flex items-center gap-2 rounded-[22px] border border-ink-100 bg-surface p-2 pl-5 shadow-card focus-within:border-purple-200"
        >
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={streaming ? "모찌가 답하는 중…" : "기록에 대해 물어보세요"}
            disabled={streaming}
            aria-label="모찌에게 질문"
            className="min-w-0 flex-1 bg-transparent text-[14.5px] outline-none placeholder:text-ink-300 disabled:opacity-60"
          />
          <button
            type="submit"
            disabled={streaming || !input.trim()}
            aria-label="보내기"
            className={cn(
              "flex size-10 flex-none items-center justify-center rounded-full transition-[background-color,transform] active:scale-[0.95]",
              input.trim() && !streaming
                ? "bg-gradient-to-br from-purple-400 to-purple-600 text-white shadow-fab"
                : "bg-ink-100 text-ink-300",
            )}
          >
            <ArrowUp className="size-4.5" strokeWidth={2.6} aria-hidden />
          </button>
        </form>
        </BorderBeam>
      </div>
    </main>
  );
}
