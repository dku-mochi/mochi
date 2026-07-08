import { Hourglass, Layers, RotateCcw, Link2 } from "lucide-react";
import type { RecallKind } from "@seed/schema";
import { cn } from "@/lib/cn";

/*
 * 회수 이유 칩 — iOS RecallReasonKind 4종 (라벨·색·아이콘 정본: RecallFeature.swift).
 * "왜 지금 떠올랐는지"를 증명하는 칩 — 색만으로 구분 금지, 아이콘+라벨 동반.
 */
export const REASON_META: Record<
  RecallKind,
  {
    label: string;
    Icon: typeof Hourglass;
    chip: string;
    fg: string;
    /** focalGlow — 덱 뒤 공간이 물드는 색 */
    glow: string;
  }
> = {
  fadingValue: {
    label: "잊기 전에 한 번",
    Icon: Hourglass,
    chip: "bg-[#FFEFE6]",
    fg: "text-[#C2570F]",
    glow: "#FF9B73",
  },
  relatedCluster: {
    label: "관련해서 여러 번",
    Icon: Layers,
    chip: "bg-purple-100",
    fg: "text-purple-600",
    glow: "#8B6CFF",
  },
  revisitedOften: {
    label: "요즘 자주 보시던",
    Icon: RotateCcw,
    chip: "bg-mint-100",
    fg: "text-[#187A4E]",
    glow: "#4CCB8F",
  },
  linkedToRecent: {
    label: "지금 맥락과 이어져요",
    Icon: Link2,
    chip: "bg-sky-100",
    fg: "text-[#1D5FB8]",
    glow: "#6BA9FF",
  },
};

export function ReasonChip({
  kind,
  className,
}: {
  kind: RecallKind;
  className?: string;
}) {
  const meta = REASON_META[kind];
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[12.5px] font-semibold",
        meta.chip,
        meta.fg,
        className,
      )}
    >
      <meta.Icon className="size-3.5" strokeWidth={2.4} aria-hidden />
      {meta.label}
    </span>
  );
}
