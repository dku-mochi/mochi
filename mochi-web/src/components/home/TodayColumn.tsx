"use client";

import Link from "next/link";
import { motion, useReducedMotion } from "framer-motion";
import { Check } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import {
  activeTodos,
  doneTodos,
  calendarMap,
  upcomingSchedules,
  dday,
  koreanDate,
} from "@/lib/seedRuntime";
import { cn } from "@/lib/cn";

/*
 * 홈 우측 "오늘" 컬럼 — 분류를 자랑하지 않고 행동으로 보여주는 자리:
 * 체크되는 할일, 마감 점이 찍힌 캘린더, 다가오는 일정.
 */

export function TodayColumn() {
  return (
    <div className="space-y-4">
      <TodoCard />
      <CalendarCard />
      <UpcomingCard />
    </div>
  );
}

function TodoCard() {
  const { persona, items, now, isTodoDone, toggleTodo } = usePersona();
  const reduce = useReducedMotion();
  const active = activeTodos(items);
  const done = doneTodos(items);

  const rows = [
    ...active.map(({ item, inst }) => ({ item, inst, base: false })),
    ...done.map(({ item, inst }) => ({ item, inst, base: true })),
  ].map((row) => ({
    ...row,
    idx: row.item.instances.indexOf(row.inst),
  }));

  return (
    <section
      aria-label="할 일"
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <div className="flex items-baseline justify-between">
        <h2 className="text-[17px] font-extrabold tracking-snug">할 일</h2>
        <span className="text-[12.5px] font-semibold text-ink-500 tnum">
          {rows.filter((r) => !isTodoDone(r.item.slug, r.idx, r.base)).length}개 남음
        </span>
      </div>
      <ul className="mt-3 space-y-0.5">
        {rows.slice(0, 6).map(({ item, inst, base, idx }) => {
          const checked = isTodoDone(item.slug, idx, base);
          const label = inst.payload?.title ?? inst.label ?? item.title;
          return (
            <li key={`${item.slug}:${idx}`} className="flex items-center gap-3 py-2">
              <button
                role="checkbox"
                aria-checked={checked}
                aria-label={`${label} ${checked ? "완료됨" : "미완료"}`}
                onClick={() => toggleTodo(item.slug, idx, base)}
                className={cn(
                  "relative flex size-[22px] flex-none items-center justify-center rounded-[7px] border-[1.5px] transition-colors duration-200",
                  "after:absolute after:-inset-2.5 after:content-['']",
                  checked
                    ? "border-butter-400 bg-butter-400"
                    : "border-ink-300 bg-surface hover:border-butter-400",
                )}
              >
                <motion.span
                  initial={false}
                  animate={
                    reduce
                      ? { opacity: checked ? 1 : 0 }
                      : { scale: checked ? 1 : 0.25, opacity: checked ? 1 : 0 }
                  }
                  transition={{ type: "spring", duration: 0.3, bounce: 0 }}
                >
                  <Check className="size-3.5 text-white" strokeWidth={3.5} />
                </motion.span>
              </button>
              <Link
                href={`/p/${persona.slug}/items/${item.slug}`}
                className={cn(
                  "min-w-0 flex-1 truncate text-[14px] font-medium transition-[color,opacity] duration-200",
                  checked ? "text-ink-500 line-through opacity-65" : "text-ink-900",
                )}
              >
                {label}
              </Link>
              {inst.dueAt !== undefined && !checked && (
                <span
                  className={cn(
                    "flex-none rounded-full px-2 py-0.5 text-[11px] font-bold tnum",
                    inst.dueAt - now < 3 * 86_400_000
                      ? "bg-butter-100 text-[#8A6410]"
                      : "bg-bg text-ink-500",
                  )}
                >
                  {dday(inst.dueAt, now)}
                </span>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** 캘린더 점 3종 — sky=일정 · butter=마감 · purple=저장 (iOS 규약) */
function CalendarCard() {
  const { items, now } = usePersona();
  const d = new Date(now);
  const year = d.getFullYear();
  const month = d.getMonth() + 1;
  const today = d.getDate();
  const map = calendarMap(items, year, month);

  const first = new Date(year, month - 1, 1).getDay();
  const daysInMonth = new Date(year, month, 0).getDate();
  const cells: Array<number | null> = [
    ...Array.from({ length: first }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) => i + 1),
  ];

  return (
    <section
      aria-label={`${month}월 캘린더`}
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <h2 className="text-[17px] font-extrabold tracking-snug">{month}월</h2>
      <div className="mt-3 grid grid-cols-7 gap-y-1 text-center">
        {["일", "월", "화", "수", "목", "금", "토"].map((w) => (
          <span key={w} className="text-[10.5px] font-semibold text-ink-300">
            {w}
          </span>
        ))}
        {cells.map((day, i) => {
          const dots = day ? map.get(day) : undefined;
          return (
            <div key={i} className="flex h-9 flex-col items-center justify-start pt-1">
              {day && (
                <>
                  <span
                    className={cn(
                      "flex size-6 items-center justify-center rounded-full text-[12px] font-semibold tnum",
                      day === today ? "bg-purple-500 text-white" : "text-ink-700",
                    )}
                  >
                    {day}
                  </span>
                  <span className="mt-0.5 flex gap-[3px]" aria-hidden>
                    {dots && dots.schedule > 0 && (
                      <i className="size-[4.5px] rounded-full bg-sky-400" />
                    )}
                    {dots && dots.deadline > 0 && (
                      <i className="size-[4.5px] rounded-full bg-butter-400" />
                    )}
                    {dots && dots.saved > 0 && (
                      <i className="size-[4.5px] rounded-full bg-purple-400" />
                    )}
                  </span>
                </>
              )}
            </div>
          );
        })}
      </div>
      <div className="mt-3 flex gap-4 border-t border-ink-100 pt-3">
        {[
          ["일정", "bg-sky-400"],
          ["마감", "bg-butter-400"],
          ["저장", "bg-purple-400"],
        ].map(([label, color]) => (
          <span key={label} className="flex items-center gap-1.5 text-[11px] font-medium text-ink-500">
            <i className={`size-[5px] rounded-full ${color}`} aria-hidden />
            {label}
          </span>
        ))}
      </div>
    </section>
  );
}

function UpcomingCard() {
  const { persona, items, now } = usePersona();
  const upcoming = upcomingSchedules(items, now).slice(0, 3);
  if (upcoming.length === 0) return null;

  return (
    <section
      aria-label="다가오는 일정"
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <h2 className="text-[17px] font-extrabold tracking-snug">다가오는 일정</h2>
      <ul className="mt-3 space-y-2.5">
        {upcoming.map(({ item, inst }, i) => {
          const date = new Date(inst.dueAt!);
          return (
            <li key={`${item.slug}-${i}`}>
              <Link
                href={`/p/${persona.slug}/items/${item.slug}`}
                className="flex items-center gap-3 rounded-xl p-1.5 -m-1.5 transition-colors hover:bg-bg"
              >
                <span className="flex size-11 flex-none flex-col items-center justify-center rounded-xl bg-sky-100 leading-none">
                  <span className="text-[9.5px] font-bold text-[#1D5FB8]">
                    {date.getMonth() + 1}월
                  </span>
                  <span className="mt-0.5 text-[16px] font-extrabold text-[#1D5FB8] tnum">
                    {date.getDate()}
                  </span>
                </span>
                <span className="min-w-0">
                  <span className="block truncate text-[14px] font-semibold text-ink-900">
                    {inst.payload?.title ?? inst.label ?? item.title}
                  </span>
                  <span className="mt-0.5 block text-[12px] text-ink-500">
                    {koreanDate(inst.dueAt!)}
                    {inst.payload?.time ? ` · ${inst.payload.time}` : ""} ·{" "}
                    {dday(inst.dueAt!, now)}
                  </span>
                </span>
              </Link>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
