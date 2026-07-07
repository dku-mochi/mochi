"use client";

import { motion, useReducedMotion } from "framer-motion";
import type { ReactNode } from "react";

/*
 * iOS HomeDesign.riseIn 이식 — spring(response 0.5, damping 0.86) ≈ duration 0.5/bounce 0.14,
 * y 16→0, index*0.06 스태거. Reduce Motion 시 이동 없이 페이드만.
 */
export function RiseIn({
  index = 0,
  children,
  className,
}: {
  index?: number;
  children: ReactNode;
  className?: string;
}) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      className={className}
      initial={reduce ? { opacity: 0 } : { opacity: 0, y: 16 }}
      animate={reduce ? { opacity: 1 } : { opacity: 1, y: 0 }}
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
