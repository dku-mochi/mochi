"use client";

import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { Eye, EyeOff } from "lucide-react";
import { cn } from "@/lib/cn";

/* ─────────────────────────────────────────────────────────────
   JudgeMode — "심사위원 보기" 전역 토글.
   제품은 intent 를 라벨 없이 BehaviorMark(행동의 형태)로만 노출한다.
   심사위원 모드가 켜지면 각 BehaviorMark 옆에 INTENT_LABEL(일정/할일/
   지식/기록)이 드러나 "무엇으로 분류했는지" 가 보인다. (entity·회수이유는
   섹션에 이미 상시 노출.) 기본 off — 평소엔 미션대로 라벨을 숨긴다.
   ───────────────────────────────────────────────────────────── */

interface JudgeModeValue {
  on: boolean;
  toggle: () => void;
}

const JudgeModeContext = createContext<JudgeModeValue>({ on: false, toggle: () => {} });

export function JudgeModeProvider({ children }: { children: ReactNode }) {
  const [on, setOn] = useState(false);
  const toggle = useCallback(() => setOn((v) => !v), []);
  const value = useMemo(() => ({ on, toggle }), [on, toggle]);
  return <JudgeModeContext.Provider value={value}>{children}</JudgeModeContext.Provider>;
}

export function useJudgeMode(): JudgeModeValue {
  return useContext(JudgeModeContext);
}

/* ── 우상단 토글 버튼 ──────────────────────────────────────── */
export function JudgeToggle() {
  const { on, toggle } = useJudgeMode();
  return (
    <button
      type="button"
      onClick={toggle}
      aria-pressed={on}
      className={cn(
        "fixed right-4 top-4 z-50 inline-flex items-center gap-2 rounded-full px-3.5 py-2",
        "text-xs font-bold tracking-tight shadow-card backdrop-blur-md",
        "transition-[transform,background-color,box-shadow] duration-150 ease-out active:scale-[0.97]",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-purple-400/60 focus-visible:ring-offset-2 focus-visible:ring-offset-canvas",
        on
          ? "bg-ink-900 text-white"
          : "border border-black/10 bg-white/70 text-ink-500 hover:text-ink-900",
      )}
    >
      {on ? (
        <Eye className="h-3.5 w-3.5" strokeWidth={2.4} />
      ) : (
        <EyeOff className="h-3.5 w-3.5" strokeWidth={2.4} />
      )}
      심사위원 보기
    </button>
  );
}
