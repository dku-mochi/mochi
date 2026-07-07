"use client";

import Image from "next/image";
import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowUp } from "lucide-react";
import { BorderBeam } from "border-beam";
import { usePersona } from "@/components/journey/PersonaProvider";
import { useChatStream } from "@/lib/hooks/useChatStream";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ChatBubble } from "./ChatBubble";
import { cn } from "@/lib/cn";

/*
 * S5 질문 씬 — 자연어로 기억을 꺼낸다.
 * 증명: 근거 인용(citation) + 쓰기는 proposal 확정으로만 (신뢰 가능한 에이전트).
 */
export function ChatScene({ initialQuery }: { initialQuery?: string }) {
  const { persona, items } = usePersona();
  const knownSlugs = useMemo(() => new Set(items.map((i) => i.slug)), [items]);
  const { messages, streaming, send, confirmProposal, cancelProposal } =
    useChatStream(persona.slug, knownSlugs);
  const [input, setInput] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);
  const autoSent = useRef(false);

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

  const submit = (text: string) => {
    if (!text.trim() || streaming) return;
    setInput("");
    void send(text);
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
              <Image
                src="/brand/mochi-chat.png"
                alt=""
                width={88}
                height={88}
                className="mx-auto h-[76px] w-auto"
                priority
              />
            </RiseIn>
            <RiseIn index={1}>
              <h1 className="mt-4 font-display text-[24px] tracking-head">
                무엇이든 물어보세요
              </h1>
              <p className="mt-2 text-[14px] text-ink-500">
                {persona.name}님의 기록 {items.length}건을 근거와 함께 꺼내드려요
              </p>
            </RiseIn>
            <RiseIn index={2} className="mt-6 flex flex-wrap justify-center gap-2">
              {persona.suggestedChat.map((q) => (
                <button
                  key={q}
                  onClick={() => submit(q)}
                  className="rounded-full border border-purple-100 bg-purple-50 px-4 py-2.5 text-[13.5px] font-semibold text-purple-600 transition-transform active:scale-[0.97]"
                >
                  {q}
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
            {persona.suggestedChat.map((q) => (
              <button
                key={q}
                onClick={() => submit(q)}
                disabled={streaming}
                className="flex-none whitespace-nowrap rounded-full border border-ink-100 bg-surface px-3.5 py-1.5 text-[12.5px] font-semibold text-ink-500 transition-colors hover:text-purple-600 disabled:opacity-50"
              >
                {q}
              </button>
            ))}
          </div>
        )}
        <BorderBeam size="md" colorVariant="ocean" theme="light" borderRadius={22}>
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
