"use client";

import { useState } from "react";
import { motion } from "framer-motion";
import type { IntentType } from "@seed/schema";
import { usePersona } from "@/components/journey/PersonaProvider";
import { ItemTile } from "@/components/tiles/ItemTile";
import { INTENT_META } from "@/components/primitives/IntentChip";
import { cn } from "@/lib/cn";

/*
 * 최근 기록 모자이크 — intent 칩은 "필터"라는 행동으로만 분류를 드러낸다.
 */
const FILTERS: Array<{ key: IntentType | "all"; label: string }> = [
  { key: "all", label: "전체" },
  { key: "schedule", label: "일정" },
  { key: "todo", label: "할일" },
  { key: "knowledge", label: "지식" },
  { key: "memo", label: "기록" },
];

export function RecentMosaic() {
  const { persona, items, now } = usePersona();
  const [filter, setFilter] = useState<IntentType | "all">("all");

  const filtered =
    filter === "all"
      ? items
      : items.filter((i) => i.instances.some((x) => x.intentType === filter));

  return (
    <section aria-label="최근 기록">
      <div className="flex flex-wrap items-center justify-between gap-y-2.5">
        <h2 className="whitespace-nowrap text-[17px] font-extrabold tracking-snug">
          최근에 보낸 것들
        </h2>
        <div
          className="-mx-1 flex gap-1.5 overflow-x-auto whitespace-nowrap px-1 max-md:w-full"
          role="group"
          aria-label="종류 필터"
        >
          {FILTERS.map(({ key, label }) => {
            const active = filter === key;
            const meta = key !== "all" ? INTENT_META[key] : null;
            return (
              <button
                key={key}
                onClick={() => setFilter(key)}
                aria-pressed={active}
                className={cn(
                  "flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-[12.5px] font-semibold transition-colors duration-200",
                  active
                    ? "border-ink-900 bg-ink-900 text-white"
                    : "border-ink-100 bg-surface text-ink-500 hover:text-ink-900",
                )}
              >
                {meta && (
                  <meta.Icon
                    className={cn("size-3.5", active ? "text-white" : meta.dot)}
                    strokeWidth={2.4}
                    aria-hidden
                  />
                )}
                {label}
              </button>
            );
          })}
        </div>
      </div>

      <motion.div layout className="mt-4 columns-2 gap-4 md:columns-3 [&>*]:mb-4 [&>*]:break-inside-avoid">
        {filtered.map((item) => (
          <ItemTile
            key={item.slug}
            item={item}
            now={now}
            href={`/p/${persona.slug}/items/${item.slug}`}
          />
        ))}
      </motion.div>
      {filtered.length === 0 && (
        <p className="mt-8 text-center text-[14px] text-ink-500">
          이 종류로 남긴 기록이 아직 없어요
        </p>
      )}
    </section>
  );
}
