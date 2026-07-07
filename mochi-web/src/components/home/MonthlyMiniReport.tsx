"use client";

import Image from "next/image";
import { motion, useReducedMotion } from "framer-motion";
import type { IntentType } from "@seed/schema";
import { usePersona } from "@/components/journey/PersonaProvider";
import { monthlyReport } from "@/lib/seedRuntime";
import { RollingNumber } from "@/components/primitives/RollingNumber";
import { INTENT_META } from "@/components/primitives/IntentChip";

/*
 * iOS MonthlyDigestView 이식 — stacked bar + 2열 범례 + 숫자 롤링,
 * mochi-peek 가 카드 모서리에서 빼꼼 (브랜드 포인트).
 */
const BAR_COLORS: Record<IntentType, string> = {
  schedule: "bg-sky-400",
  todo: "bg-butter-400",
  knowledge: "bg-mint-400",
  memo: "bg-blush-400",
};

const ORDER: IntentType[] = ["schedule", "todo", "knowledge", "memo"];

export function MonthlyMiniReport() {
  const { items, now } = usePersona();
  const reduce = useReducedMotion();
  const report = monthlyReport(items, now);
  const month = new Date(now).getMonth() + 1;

  return (
    <section
      aria-label="이번 달 리포트"
      className="relative rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <Image
        src="/brand/mochi-peek.png"
        alt=""
        width={74}
        height={44}
        className="pointer-events-none absolute -top-[26px] right-6 h-[34px] w-auto"
        aria-hidden
      />
      <div className="flex items-baseline justify-between">
        <h2 className="text-[17px] font-extrabold tracking-snug">
          {month}월의 기록
        </h2>
        <span className="text-[13px] font-semibold text-ink-500">
          <RollingNumber value={report.total} className="text-ink-900" />개 저장
        </span>
      </div>

      <div
        className="mt-4 flex h-3 overflow-hidden rounded-full bg-bg"
        role="img"
        aria-label={ORDER.map(
          (k) => `${INTENT_META[k].label} ${report.byIntent[k]}개`,
        ).join(", ")}
      >
        {ORDER.filter((k) => report.byIntent[k] > 0).map((k) => (
          <motion.div
            key={k}
            className={BAR_COLORS[k]}
            initial={reduce ? false : { scaleX: 0 }}
            animate={{ scaleX: 1 }}
            style={{
              width: `${(report.byIntent[k] / Math.max(report.total, 1)) * 100}%`,
              originX: 0,
            }}
            transition={{ type: "spring", duration: 0.7, bounce: 0 }}
          />
        ))}
      </div>

      <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-2.5">
        {ORDER.map((k) => (
          <div key={k} className="flex items-center gap-2">
            <span className={`size-2 rounded-full ${BAR_COLORS[k]}`} aria-hidden />
            <dt className="text-[13px] font-medium text-ink-500">
              {INTENT_META[k].label}
            </dt>
            <dd className="ml-auto text-[13px] font-bold tnum">
              {report.byIntent[k]}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
