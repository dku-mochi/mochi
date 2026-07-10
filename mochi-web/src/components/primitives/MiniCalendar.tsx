"use client";

import Link from "next/link";
import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { kstParts, type CalendarEntry, type CalendarEntryKind } from "@/lib/seedRuntime";
import { cn } from "@/lib/cn";

/*
 * 클릭되는 미니 캘린더 — 홈(TodayColumn)과 기록 보드(CaptureScene)가 공유.
 * 점 3종(sky=일정 · butter=마감 · purple=저장, iOS 규약)은 entries 에서 파생되고,
 * 점이 있는 날짜는 버튼이 되어 그 날의 항목 리스트를 아래에 펼친다.
 */

const KIND_META: Record<CalendarEntryKind, { label: string; dot: string }> = {
  schedule: { label: "일정", dot: "bg-sky-400" },
  deadline: { label: "마감", dot: "bg-butter-400" },
  saved: { label: "저장", dot: "bg-purple-400" },
};

const KIND_ORDER: CalendarEntryKind[] = ["schedule", "deadline", "saved"];
const WEEKDAYS = ["일", "월", "화", "수", "목", "금", "토"];

export function MiniCalendar({
  now,
  entries,
  hrefFor,
  legend = false,
  dense = false,
}: {
  now: number;
  entries: Map<number, CalendarEntry[]>;
  /** 항목 클릭 시 이동할 링크 — 없으면 항목은 텍스트로만 */
  hrefFor?: (slug: string) => string;
  legend?: boolean;
  dense?: boolean;
}) {
  const { year, month, day: today } = kstParts(now);
  const [selected, setSelected] = useState<number | null>(null);
  // 항목이 사라진 날짜의 선택은 조용히 해제
  const openDay = selected !== null && entries.has(selected) ? selected : null;
  const openEntries = openDay !== null ? (entries.get(openDay) ?? []) : [];

  const first = new Date(Date.UTC(year, month - 1, 1)).getUTCDay();
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const cells: Array<number | null> = [
    ...Array.from({ length: first }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) => i + 1),
  ];

  return (
    <div>
      <div
        className={cn(
          "grid grid-cols-7 text-center",
          dense ? "gap-y-0.5" : "gap-y-1",
        )}
      >
        {WEEKDAYS.map((w) => (
          <span
            key={w}
            className={cn(
              "font-semibold text-ink-300",
              dense ? "text-[10px]" : "text-[10.5px]",
            )}
          >
            {w}
          </span>
        ))}
        {cells.map((day, i) => {
          const dayEntries = day ? entries.get(day) : undefined;
          const kinds = dayEntries
            ? KIND_ORDER.filter((k) => dayEntries.some((e) => e.kind === k))
            : [];
          const summary = dayEntries
            ? KIND_ORDER.map((k) => {
                const n = dayEntries.filter((e) => e.kind === k).length;
                return n > 0 ? `${KIND_META[k].label} ${n}개` : null;
              })
                .filter(Boolean)
                .join(", ")
            : "";
          const isOpen = day !== null && day === openDay;

          const face = day && (
            <>
              <span
                className={cn(
                  "flex items-center justify-center rounded-full font-semibold tnum transition-colors",
                  dense ? "size-[22px] text-[11.5px]" : "size-6 text-[12px]",
                  day === today
                    ? "bg-purple-500 text-white"
                    : isOpen
                      ? "bg-purple-100 text-purple-600"
                      : "text-ink-700",
                )}
              >
                {day}
              </span>
              <span className="mt-0.5 flex h-[5px] gap-[3px]" aria-hidden>
                {kinds.map((k) => (
                  <i
                    key={k}
                    className={cn("size-[4.5px] rounded-full", KIND_META[k].dot)}
                  />
                ))}
              </span>
            </>
          );

          return dayEntries ? (
            <button
              key={i}
              type="button"
              onClick={() => setSelected(isOpen ? null : day)}
              aria-expanded={isOpen}
              aria-label={`${month}월 ${day}일 — ${summary}`}
              className={cn(
                "flex flex-col items-center rounded-lg pt-1 transition-colors hover:bg-purple-50",
                dense ? "h-8" : "h-9",
              )}
            >
              {face}
            </button>
          ) : (
            <div
              key={i}
              className={cn(
                "flex flex-col items-center pt-1",
                dense ? "h-8" : "h-9",
              )}
              aria-label={day ? `${month}월 ${day}일` : undefined}
            >
              {face}
            </div>
          );
        })}
      </div>

      <AnimatePresence initial={false}>
        {openDay !== null && (
          <motion.div
            key={openDay}
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={{ type: "spring", duration: 0.4, bounce: 0 }}
            className="overflow-hidden"
          >
            <div
              className={cn(
                "mt-2 rounded-xl bg-bg/80 px-3 py-2.5",
                dense && "px-2.5 py-2",
              )}
            >
              <p className="text-[11px] font-bold text-ink-500 tnum">
                {month}월 {openDay}일 ({WEEKDAYS[new Date(Date.UTC(year, month - 1, openDay)).getUTCDay()]})
              </p>
              <ul className="mt-1.5 space-y-1">
                {openEntries.map((e) => {
                  const row = (
                    <>
                      <i
                        className={cn(
                          "size-[5px] flex-none rounded-full",
                          KIND_META[e.kind].dot,
                        )}
                        aria-hidden
                      />
                      <span className="min-w-0 flex-1 truncate text-[12.5px] font-semibold text-ink-900">
                        {e.title}
                      </span>
                      <span className="flex-none text-[10.5px] font-medium text-ink-500 tnum">
                        {e.time ?? KIND_META[e.kind].label}
                      </span>
                    </>
                  );
                  return (
                    <li key={e.key}>
                      {hrefFor ? (
                        <Link
                          href={hrefFor(e.slug)}
                          className="-mx-1 flex items-center gap-2 rounded-lg px-1 py-0.5 transition-colors hover:bg-surface"
                        >
                          {row}
                        </Link>
                      ) : (
                        <span className="flex items-center gap-2 py-0.5">{row}</span>
                      )}
                    </li>
                  );
                })}
              </ul>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {legend && (
        <div className="mt-3 flex gap-4 border-t border-ink-100 pt-3">
          {KIND_ORDER.map((k) => (
            <span
              key={k}
              className="flex items-center gap-1.5 text-[11px] font-medium text-ink-500"
            >
              <i className={cn("size-[5px] rounded-full", KIND_META[k].dot)} aria-hidden />
              {KIND_META[k].label}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
