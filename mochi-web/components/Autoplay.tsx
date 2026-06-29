"use client";

import { useEffect, useRef, useState } from "react";
import { Play, Pause } from "lucide-react";
import { useReducedMotion } from "framer-motion";
import { cn } from "@/lib/cn";

/* ─────────────────────────────────────────────────────────────
   Autoplay — 핵심 섹션을 천천히 훑어 보여주는 "둘러보기" 옵션.
   ★ 기본 off — 진입 시 Hero(코버플로우, 첫인상)가 항상 맨 먼저 보인다.
   사용자가 직접 켜면 Hero → 보이지 않는 정리(story-save) → Live 순으로
   부드럽게 흐른다. 스크롤·터치·키를 건드리면 즉시 양보한다.
   prefers-reduced-motion 이면 버튼 자체를 띄우지 않는다.
   ───────────────────────────────────────────────────────────── */

// 천천히 멈춰 가며 보여줄 섹션 — Hero 부터 시작해 첫 진입 핵심까지.
const TOUR: { id: string; dwellMs: number }[] = [
  { id: "top", dwellMs: 2800 },
  { id: "story-save", dwellMs: 3600 },
  { id: "live", dwellMs: 4200 },
];

export function Autoplay() {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(false);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);

  // 투어 진행 중에만 예약 스크롤 + 인터랙션 양보 리스너를 건다.
  useEffect(() => {
    if (!active) return;

    const clearTimers = () => {
      timers.current.forEach(clearTimeout);
      timers.current = [];
    };

    const stop = () => {
      clearTimers();
      setActive(false);
    };

    // 사용자가 스스로 움직이면 투어를 양보한다.
    const opts = { passive: true } as const;
    window.addEventListener("wheel", stop, opts);
    window.addEventListener("touchstart", stop, opts);
    window.addEventListener("keydown", stop);

    // Hero 부터 순차적으로 다음 섹션을 부드럽게 노출.
    let t = 0;
    for (const step of TOUR) {
      timers.current.push(
        setTimeout(() => {
          document.getElementById(step.id)?.scrollIntoView({ behavior: "smooth", block: "start" });
        }, t),
      );
      t += step.dwellMs;
    }
    // 투어 종료 후 자동으로 수동 모드 전환.
    timers.current.push(setTimeout(() => setActive(false), t));

    return () => {
      clearTimers();
      window.removeEventListener("wheel", stop);
      window.removeEventListener("touchstart", stop);
      window.removeEventListener("keydown", stop);
    };
  }, [active]);

  if (reduce) return null;

  return (
    <button
      type="button"
      onClick={() => setActive((v) => !v)}
      aria-pressed={active}
      className={cn(
        "fixed bottom-5 left-1/2 z-50 inline-flex -translate-x-1/2 items-center gap-2 rounded-full",
        "border border-black/10 bg-white/80 px-4 py-2 text-xs font-bold tracking-tight text-ink-500 shadow-float backdrop-blur-md",
        "transition-[transform,color,background-color] duration-150 ease-out active:scale-[0.97] hover:text-ink-900",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-purple-400/60 focus-visible:ring-offset-2 focus-visible:ring-offset-canvas",
      )}
    >
      {active ? (
        <>
          <Pause className="h-3.5 w-3.5" strokeWidth={2.6} />
          멈추고 직접 보기
        </>
      ) : (
        <>
          <Play className="h-3.5 w-3.5" strokeWidth={2.6} />
          천천히 둘러보기
        </>
      )}
    </button>
  );
}
