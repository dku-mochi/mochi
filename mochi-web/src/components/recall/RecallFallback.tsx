"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useRef } from "react";
import { ArrowLeft, ArrowRight, ArrowUpRight } from "lucide-react";
import type { SeedRecallEntry } from "@seed/schema";
import type { ResolvedItem } from "@/lib/seedRuntime";
import { usePersona } from "@/components/journey/PersonaProvider";
import { ReasonChip } from "@/components/primitives/ReasonChip";
import { cn } from "@/lib/cn";

/*
 * 코버플로우 폴백 — prefers-reduced-motion / WebGL 불가 환경.
 * 카드 1장 + 페이지네이션. 기능 손실 0 원칙 — ← → 키도 코버플로우와 동일하게 동작.
 */
export function RecallFallback({
  entries,
  items,
  focal,
  onFocalChange,
}: {
  entries: SeedRecallEntry[];
  items: ResolvedItem[];
  focal: number;
  onFocalChange: (i: number) => void;
}) {
  const { persona } = usePersona();
  const rootRef = useRef<HTMLDivElement>(null);
  const item = items[focal];
  const entry = entries[focal];
  const count = items.length;

  // 진입 시 포커스 — 레일 힌트("← → 는 카드 넘기기")가 폴백에서도 참이 되게
  useEffect(() => {
    rootRef.current?.focus({ preventScroll: true });
  }, []);

  return (
    <div
      ref={rootRef}
      role="group"
      data-owns-arrows
      aria-roledescription="캐러셀"
      aria-label={`떠오른 기록 ${count}개 중 ${focal + 1}번째: ${item.title}`}
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft" && e.key !== "Enter") return;
        e.preventDefault();
        e.stopPropagation();
        if (e.key === "ArrowRight") onFocalChange((focal + 1) % count);
        if (e.key === "ArrowLeft") onFocalChange((focal - 1 + count) % count);
        if (e.key === "Enter")
          window.location.assign(`/p/${persona.slug}/items/${item.slug}`);
      }}
      className="mx-auto flex w-full max-w-xl flex-1 flex-col items-center justify-center gap-5 px-5 pb-8 text-center"
    >
      <div className="w-[240px] overflow-hidden rounded-2xl shadow-card-lift ring-1 ring-black/10">
        {item.image ? (
          <Image
            src={item.image.file}
            alt={item.title}
            width={item.image.width}
            height={item.image.height}
            className="h-[380px] w-full object-cover object-top"
          />
        ) : (
          <div
            className={cn(
              "flex h-[380px] flex-col justify-between p-5 text-left",
              item.kind === "url" ? "bg-purple-50" : "bg-butter-50",
            )}
          >
            <p className="text-[17px] font-bold leading-snug">{item.title}</p>
            <p className="text-[12px] font-medium text-ink-500">{item.source}</p>
          </div>
        )}
      </div>

      <div>
        <ReasonChip kind={entry.kind} />
        <h2 className="mt-2.5 font-display text-[21px] leading-snug tracking-head [text-wrap:balance]">
          {entry.oneline}
        </h2>
        <p className="mt-1.5 text-[13.5px] text-ink-500">{entry.gist.join(" · ")}</p>
        <Link
          href={`/p/${persona.slug}/items/${item.slug}`}
          className="mt-3.5 inline-flex h-10 items-center gap-1 rounded-full bg-ink-900 px-5 text-[13.5px] font-bold text-white"
        >
          이 기록 열기 <ArrowUpRight className="size-4" aria-hidden />
        </Link>
      </div>

      <div className="flex items-center gap-4">
        <button
          onClick={() => onFocalChange((focal - 1 + count) % count)}
          aria-label="이전 기록"
          className="flex size-11 items-center justify-center rounded-full border border-ink-100 bg-surface text-ink-700 shadow-card"
        >
          <ArrowLeft className="size-4" aria-hidden />
        </button>
        <span className="text-[13px] font-semibold text-ink-500 tnum">
          {focal + 1} / {count}
        </span>
        <button
          onClick={() => onFocalChange((focal + 1) % count)}
          aria-label="다음 기록"
          className="flex size-11 items-center justify-center rounded-full border border-ink-100 bg-surface text-ink-700 shadow-card"
        >
          <ArrowRight className="size-4" aria-hidden />
        </button>
      </div>
    </div>
  );
}
