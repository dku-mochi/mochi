import { Calendar, ListChecks, BookOpen, FileText } from "lucide-react";
import type { IntentType } from "@seed/schema";
import { cn } from "@/lib/cn";

/*
 * iOS IntentChip 이식 — 색만으로 구분 금지, 항상 아이콘+라벨.
 * 색 매핑 정본: HomeViewMapping.swift (일정 sky / 할일 butter / 지식 mint / 기록 blush)
 */
export const INTENT_META: Record<
  IntentType,
  { label: string; chip: string; dot: string; Icon: typeof Calendar }
> = {
  schedule: { label: "일정", chip: "bg-sky-100", dot: "text-sky-400", Icon: Calendar },
  todo: { label: "할일", chip: "bg-butter-100", dot: "text-butter-400", Icon: ListChecks },
  knowledge: { label: "지식", chip: "bg-mint-100", dot: "text-mint-400", Icon: BookOpen },
  memo: { label: "기록", chip: "bg-blush-100", dot: "text-blush-400", Icon: FileText },
};

export function IntentChip({
  intent,
  size = "md",
  className,
}: {
  intent: IntentType;
  size?: "sm" | "md";
  className?: string;
}) {
  const meta = INTENT_META[intent];
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full font-semibold text-ink-900",
        meta.chip,
        size === "sm" ? "gap-1 px-2 py-0.5 text-[11px]" : "gap-1.5 px-2.5 py-1 text-[12.5px]",
        className,
      )}
    >
      <meta.Icon
        className={cn(meta.dot, size === "sm" ? "size-3" : "size-3.5")}
        strokeWidth={2.4}
        aria-hidden
      />
      {meta.label}
    </span>
  );
}
