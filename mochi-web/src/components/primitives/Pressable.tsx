"use client";

import { motion, useReducedMotion } from "framer-motion";
import type { ComponentProps } from "react";

/*
 * iOS PressableStyle 이식 — 누르면 scale 0.97 + opacity 0.85, spring 복귀.
 */
type Props = ComponentProps<typeof motion.button>;

export function Pressable({ children, ...rest }: Props) {
  const reduce = useReducedMotion();
  return (
    <motion.button
      whileTap={reduce ? undefined : { scale: 0.97, opacity: 0.85 }}
      transition={{ type: "spring", duration: 0.28, bounce: 0.3 }}
      {...rest}
    >
      {children}
    </motion.button>
  );
}
