"use client";

import { motion, useReducedMotion } from "framer-motion";
import type { ReactNode } from "react";

/*
 * iOS HomeDesign.riseIn 이식 — spring(response 0.5, damping 0.86) ≈ duration 0.5/bounce 0.14,
 * y 16→0, index*0.06 스태거. Reduce Motion 시 이동 없이 페이드만.
 */
export function RiseIn({
  index = 0,
  inView = false,
  children,
  className,
}: {
  index?: number;
  /** true 면 마운트가 아니라 뷰포트 진입 시 1회 재생 (스크롤 아래 섹션용) */
  inView?: boolean;
  children: ReactNode;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const hidden = reduce ? { opacity: 0 } : { opacity: 0, y: 16 };
  const shown = reduce ? { opacity: 1 } : { opacity: 1, y: 0 };
  return (
    <motion.div
      className={className}
      initial={hidden}
      {...(inView
        ? { whileInView: shown, viewport: { once: true, amount: 0.25 } }
        : { animate: shown })}
      transition={{
        type: "spring",
        duration: 0.5,
        bounce: 0.14,
        delay: index * 0.06,
      }}
    >
      {children}
    </motion.div>
  );
}
