"use client";

import { motion, useReducedMotion } from "framer-motion";
import { Sparkles } from "lucide-react";

/*
 * iOS ChatBubbleView 의 ToolStatusPill — "기록을 뒤지고 있어요…" + 호흡하는 sparkles.
 */
export function ToolStatusPill({ label }: { label: string }) {
  const reduce = useReducedMotion();
  return (
    <span className="inline-flex items-center gap-2 rounded-full bg-purple-50 px-3.5 py-2 text-[13px] font-semibold text-purple-600">
      <motion.span
        animate={reduce ? undefined : { scale: [1, 1.25, 1], opacity: [0.7, 1, 0.7] }}
        transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
        className="inline-flex"
        aria-hidden
      >
        <Sparkles className="size-3.5" />
      </motion.span>
      {label}
    </span>
  );
}

/** iOS TypingDots — 순차 바운스 점 3개 */
export function TypingDots() {
  const reduce = useReducedMotion();
  return (
    <span className="inline-flex items-center gap-1 px-1 py-2" aria-label="답변 작성 중">
      {[0, 1, 2].map((i) => (
        <motion.span
          key={i}
          className="size-1.5 rounded-full bg-ink-300"
          animate={reduce ? { opacity: [0.4, 1, 0.4] } : { y: [0, -4, 0] }}
          transition={{
            duration: 0.9,
            repeat: Infinity,
            delay: i * 0.14,
            ease: "easeInOut",
          }}
        />
      ))}
    </span>
  );
}
