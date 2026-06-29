"use client";

import type { ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

interface PillButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "ghost";
}

export function PillButton({
  variant = "primary",
  className,
  children,
  ...props
}: PillButtonProps) {
  return (
    <button
      {...props}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-full px-5 py-2.5",
        "text-sm font-bold tracking-tight select-none",
        "transition-[transform,background-color,box-shadow] duration-150 ease-out",
        "active:scale-[0.97] disabled:opacity-40 disabled:active:scale-100",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-purple-400/60 focus-visible:ring-offset-2 focus-visible:ring-offset-canvas",
        variant === "primary"
          ? "bg-ink-900 text-white shadow-card hover:bg-ink-900/90"
          : "border border-black/10 bg-white/60 text-ink-900 backdrop-blur-md hover:bg-white/80",
        className
      )}
    >
      {children}
    </button>
  );
}
