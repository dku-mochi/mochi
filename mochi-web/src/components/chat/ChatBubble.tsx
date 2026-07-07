"use client";

import { useState } from "react";
import Link from "next/link";
import { motion } from "framer-motion";
import { Check, ChevronDown } from "lucide-react";
import type { AssistantMessage, ChatMessage } from "@/lib/hooks/useChatStream";
import { usePersona } from "@/components/journey/PersonaProvider";
import { ToolStatusPill, TypingDots } from "@/components/primitives/ToolStatusPill";
import { ChatMarkup } from "./ChatMarkup";
import { ProposalCard } from "./ProposalCard";
import { cn } from "@/lib/cn";

/*
 * iOS ChatBubbleView 이식 — 3단 연출:
 * ToolStatusPill(호흡) → TypingDots → 마크다운 본문 → 근거 미니카드 → "과정 보기" 접기.
 */

export function ChatBubble({
  message,
  onConfirmProposal,
  onCancelProposal,
}: {
  message: ChatMessage;
  onConfirmProposal: (id: string) => void;
  onCancelProposal: (id: string) => void;
}) {
  if (message.role === "user") {
    return (
      <div className="flex justify-end">
        <div className="max-w-[78%] rounded-[18px] rounded-tr-md bg-gradient-to-br from-purple-400 to-purple-600 px-4 py-2.5 text-[14.5px] font-medium leading-relaxed text-white shadow-card">
          {message.text}
        </div>
      </div>
    );
  }
  return (
    <AssistantBubble
      m={message}
      onConfirm={onConfirmProposal}
      onCancel={onCancelProposal}
    />
  );
}

function AssistantBubble({
  m,
  onConfirm,
  onCancel,
}: {
  m: AssistantMessage;
  onConfirm: (id: string) => void;
  onCancel: (id: string) => void;
}) {
  const runningTool = m.tools.find((t) => !t.done);
  const waiting = m.streaming && m.text.length === 0;

  return (
    <motion.div
      className="flex justify-start"
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ type: "spring", duration: 0.4, bounce: 0 }}
    >
      <div className="max-w-[86%] space-y-3 rounded-[18px] rounded-tl-md border border-ink-100 bg-surface px-4 py-3.5 shadow-card">
        {waiting &&
          (runningTool ? <ToolStatusPill label={runningTool.label} /> : <TypingDots />)}

        {m.text.length > 0 && (
          <ChatMarkup text={m.text} citations={m.citations} streaming={m.streaming} />
        )}

        {m.streaming && m.text.length > 0 && (
          <span className="inline-block h-4 w-[3px] animate-pulse rounded-full bg-purple-400" aria-hidden />
        )}

        {m.citations.length > 0 && <CitationCardsRow m={m} />}

        {m.proposals.map((p) => (
          <ProposalCard
            key={p.id}
            proposal={p}
            onConfirm={() => onConfirm(p.id)}
            onCancel={() => onCancel(p.id)}
          />
        ))}

        {m.error && (
          <p className="text-[13px] font-medium text-blush-400">{m.error}</p>
        )}

        {!m.streaming && m.tools.length > 0 && <ProcessDisclosure m={m} />}
      </div>
    </motion.div>
  );
}

/** 근거 미니카드 — 위첨자 번호와 짝, 탭하면 해당 기록 상세로 */
function CitationCardsRow({ m }: { m: AssistantMessage }) {
  const { persona } = usePersona();
  return (
    <div className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1" aria-label="답변 근거">
      {m.citations.map((c) => {
        const inner = (
          <>
            <span className="flex size-[18px] flex-none items-center justify-center rounded-full bg-purple-100 text-[10px] font-bold text-purple-600">
              {c.index}
            </span>
            <span className="min-w-0">
              <span className="block truncate text-[12.5px] font-bold text-ink-900">
                {c.title}
              </span>
              <span className="block truncate text-[11px] text-ink-500">{c.snippet}</span>
            </span>
          </>
        );
        return c.slug ? (
          <Link
            key={c.index}
            href={`/p/${persona.slug}/items/${c.slug}`}
            className="flex w-[190px] flex-none items-center gap-2 rounded-xl border border-ink-100 bg-bg/60 px-2.5 py-2 transition-colors hover:bg-bg"
          >
            {inner}
          </Link>
        ) : (
          <span
            key={c.index}
            className="flex w-[190px] flex-none items-center gap-2 rounded-xl border border-ink-100 bg-bg/60 px-2.5 py-2"
          >
            {inner}
          </span>
        );
      })}
    </div>
  );
}

/** "과정 보기 · N단계" 접기 — 에이전트가 실제로 밟은 단계의 투명한 공개 */
function ProcessDisclosure({ m }: { m: AssistantMessage }) {
  const [open, setOpen] = useState(false);
  const steps = m.tools.filter((t) => t.done);
  if (steps.length === 0) return null;

  return (
    <div className="border-t border-ink-100/70 pt-2.5">
      <button
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="flex items-center gap-1 text-[12px] font-semibold text-ink-500 transition-colors hover:text-ink-900"
      >
        과정 보기 · {steps.length}단계
        <ChevronDown
          className={cn("size-3.5 transition-transform duration-200", open && "rotate-180")}
          aria-hidden
        />
      </button>
      {open && (
        <ul className="mt-2 space-y-1.5">
          {steps.map((t, i) => (
            <li key={i} className="flex items-center gap-2 text-[12.5px] text-ink-500">
              <Check className="size-3.5 flex-none text-mint-400" strokeWidth={3} aria-hidden />
              <span className="font-semibold text-ink-700">{t.label}</span>
              {t.summary && <span className="truncate">— {t.summary}</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
