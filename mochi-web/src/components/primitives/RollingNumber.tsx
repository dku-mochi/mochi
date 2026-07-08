"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";

/*
 * iOS .contentTransition(.numericText) 이식 — 자릿수별 롤링, tabular-nums.
 */
export function RollingNumber({
  value,
  className,
}: {
  value: number;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const chars = String(value).split("");
  return (
    <span className={`tnum inline-flex overflow-hidden ${className ?? ""}`}>
      {chars.map((ch, i) => (
        <span key={`${i}-${chars.length}`} className="relative inline-block">
          <AnimatePresence mode="popLayout" initial={false}>
            <motion.span
              key={ch}
              className="inline-block"
              initial={reduce ? { opacity: 0 } : { y: "0.9em", opacity: 0 }}
              animate={{ y: 0, opacity: 1 }}
              exit={reduce ? { opacity: 0 } : { y: "-0.9em", opacity: 0 }}
              transition={{ type: "spring", duration: 0.45, bounce: 0.16 }}
            >
              {ch}
            </motion.span>
          </AnimatePresence>
        </span>
      ))}
    </span>
  );
}
