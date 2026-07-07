"use client";

import Image from "next/image";
import Link from "next/link";
import { ArrowLeft, ArrowUpRight, Camera, Check, Link2 } from "lucide-react";
import { motion, useReducedMotion } from "framer-motion";
import { usePersona } from "@/components/journey/PersonaProvider";
import {
  findItem,
  relativeLabel,
  koreanDate,
  dday,
  type ResolvedItem,
} from "@/lib/seedRuntime";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ItemTile, domainOf } from "@/components/tiles/ItemTile";
import { cn } from "@/lib/cn";

/*
 * iOS DetailView 이식 — "검수가 아니라 회수".
 * 회수 헤더 → 지금 할 수 있어요 → 모찌가 정리했어요 → 비슷한 기록.
 */
export function DetailScene({ slug }: { slug: string }) {
  const { persona, items, now } = usePersona();
  const item = findItem(items, slug);
  if (!item) return null;

  const related = (item.relatedSlugs ?? [])
    .map((s) => findItem(items, s))
    .filter((x): x is ResolvedItem => Boolean(x));

  return (
    <main className="mx-auto max-w-3xl px-5 py-6">
      <RiseIn index={0}>
        <Link
          href={`/p/${persona.slug}`}
          className="inline-flex h-10 items-center gap-1.5 rounded-full text-[14px] font-semibold text-ink-500 transition-colors hover:text-ink-900"
        >
          <ArrowLeft className="size-4" aria-hidden /> 홈으로
        </Link>
      </RiseIn>

      <RiseIn index={1}>
        <DetailHero item={item} />
      </RiseIn>

      <RiseIn index={2}>
        <p className="mt-5 text-[12.5px] font-semibold uppercase tracking-wide text-ink-500">
          {item.category} · {item.source} · {relativeLabel(item.capturedAt, now)}
        </p>
        <h1 className="mt-1.5 font-display text-[26px] leading-snug tracking-head [text-wrap:balance]">
          {item.title}
        </h1>
      </RiseIn>

      <RiseIn index={3}>
        <ActionNow item={item} />
      </RiseIn>

      <RiseIn index={4}>
        <MochiSummary item={item} />
      </RiseIn>

      {related.length > 0 && (
        <RiseIn index={5}>
          <section aria-label="비슷한 기록" className="mt-8">
            <h2 className="text-[17px] font-extrabold tracking-snug">
              비슷한 기록
            </h2>
            <div className="mt-3 flex gap-3.5 overflow-x-auto pb-2 [&>*]:w-[170px] [&>*]:flex-none">
              {related.map((r) => (
                <ItemTile
                  key={r.slug}
                  item={r}
                  now={now}
                  href={`/p/${persona.slug}/items/${r.slug}`}
                  showIntent={false}
                />
              ))}
            </div>
          </section>
        </RiseIn>
      )}
    </main>
  );
}

function DetailHero({ item }: { item: ResolvedItem }) {
  if (item.image) {
    const landscape = item.image.width > item.image.height;
    return (
      <div className="relative mt-4 flex h-[440px] items-center justify-center overflow-hidden rounded-3xl bg-gradient-to-br from-purple-50 via-bg to-cream-100">
        <Image
          src={item.image.file}
          alt={`${item.title} 캡처 원본`}
          width={item.image.width}
          height={item.image.height}
          priority
          className={cn(
            "rounded-2xl shadow-card-lift ring-1 ring-black/10",
            landscape ? "h-auto w-[86%]" : "h-[396px] w-auto",
          )}
        />
        <div className="absolute inset-0 rounded-3xl ring-1 ring-inset ring-black/10" aria-hidden />
        <span className="absolute left-4 top-4 inline-flex items-center gap-1.5 rounded-full bg-ink-900/70 px-3 py-1.5 text-[12px] font-semibold text-white backdrop-blur">
          {item.kind === "screenshot" ? (
            <>
              <Camera className="size-3.5" aria-hidden /> 캡처
            </>
          ) : (
            <>
              <Link2 className="size-3.5" aria-hidden />
              {domainOf(item.url) || item.source}
            </>
          )}
        </span>
      </div>
    );
  }
  const isUrl = item.kind === "url";
  return (
    <div
      className={cn(
        "relative mt-4 flex h-[190px] items-end overflow-hidden rounded-3xl p-6",
        isUrl
          ? "bg-gradient-to-br from-purple-100 via-purple-50 to-cream-100"
          : "bg-gradient-to-br from-butter-100 via-butter-50 to-cream-100",
      )}
    >
      <span
        className={cn(
          "pointer-events-none absolute -right-3 -top-12 font-display text-[150px] leading-none",
          isUrl ? "text-purple-200/60" : "text-butter-400/20",
        )}
        aria-hidden
      >
        {isUrl ? "@" : "“"}
      </span>
      <span
        className={cn(
          "inline-flex items-center gap-2 rounded-full bg-surface/85 px-3.5 py-2 text-[13px] font-bold shadow-card backdrop-blur",
          isUrl ? "text-purple-600" : "text-[#8A6410]",
        )}
      >
        {isUrl ? <Link2 className="size-4" aria-hidden /> : null}
        {isUrl ? domainOf(item.url) : `${item.source}로 남긴 기록`}
      </span>
    </div>
  );
}

/** "지금 할 수 있어요" — 분류가 아니라 행동 (할일 체크 / 일정 타일 / 원본 열기) */
function ActionNow({ item }: { item: ResolvedItem }) {
  const { now, isTodoDone, toggleTodo } = usePersona();
  const reduce = useReducedMotion();

  const rows: React.ReactNode[] = [];

  item.instances.forEach((inst, idx) => {
    if (inst.intentType === "todo") {
      const checked = isTodoDone(item.slug, idx, inst.done ?? false);
      const label = inst.payload?.title ?? inst.label ?? item.title;
      rows.push(
        <button
          key={`todo-${idx}`}
          role="checkbox"
          aria-checked={checked}
          onClick={() => toggleTodo(item.slug, idx, inst.done ?? false)}
          className="flex w-full items-center gap-3.5 rounded-2xl p-3 text-left transition-colors hover:bg-bg"
        >
          <span
            className={cn(
              "flex size-6 flex-none items-center justify-center rounded-lg border-[1.5px] transition-colors duration-200",
              checked
                ? "border-butter-400 bg-butter-400"
                : "border-ink-300 bg-surface",
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
              <Check className="size-4 text-white" strokeWidth={3.5} />
            </motion.span>
          </span>
          <span className="min-w-0 flex-1">
            <span
              className={cn(
                "block text-[15px] font-semibold transition-[color,opacity]",
                checked ? "text-ink-500 line-through opacity-65" : "text-ink-900",
              )}
            >
              {label}
            </span>
            {inst.dueAt !== undefined && (
              <span className="mt-0.5 block text-[12.5px] text-ink-500">
                {koreanDate(inst.dueAt)}까지 · {dday(inst.dueAt, now)}
              </span>
            )}
          </span>
        </button>,
      );
    }
    if (inst.intentType === "schedule" && inst.dueAt !== undefined) {
      const date = new Date(inst.dueAt);
      rows.push(
        <div key={`sch-${idx}`} className="flex items-center gap-3.5 rounded-2xl p-3">
          <span className="flex size-12 flex-none flex-col items-center justify-center rounded-xl bg-sky-100 leading-none">
            <span className="text-[10px] font-bold text-[#1D5FB8]">
              {date.getMonth() + 1}월
            </span>
            <span className="mt-0.5 text-[17px] font-extrabold text-[#1D5FB8] tnum">
              {date.getDate()}
            </span>
          </span>
          <span className="min-w-0 flex-1">
            <span className="block text-[15px] font-semibold text-ink-900">
              {inst.payload?.title ?? inst.label ?? item.title}
            </span>
            <span className="mt-0.5 block text-[12.5px] text-ink-500">
              {koreanDate(inst.dueAt)}
              {inst.payload?.time ? ` · ${inst.payload.time}` : ""} ·{" "}
              {dday(inst.dueAt, now)}
            </span>
          </span>
        </div>,
      );
    }
  });

  if (item.url) {
    rows.push(
      <a
        key="url"
        href={item.url}
        target="_blank"
        rel="noreferrer"
        className="flex items-center gap-3.5 rounded-2xl p-3 transition-colors hover:bg-bg"
      >
        <span className="flex size-12 flex-none items-center justify-center rounded-xl bg-purple-50">
          <Link2 className="size-5 text-purple-500" aria-hidden />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[15px] font-semibold text-ink-900">
            원본 열기
          </span>
          <span className="mt-0.5 block truncate text-[12.5px] text-ink-500">
            {domainOf(item.url)}
          </span>
        </span>
        <ArrowUpRight className="size-4 flex-none text-ink-300" aria-hidden />
      </a>,
    );
  }

  if (rows.length === 0) return null;
  return (
    <section
      aria-label="지금 할 수 있어요"
      className="mt-6 rounded-3xl border border-ink-100 bg-surface p-2.5 shadow-card"
    >
      <h2 className="px-3 pb-1 pt-2.5 text-[13px] font-bold text-ink-500">
        지금 할 수 있어요
      </h2>
      <div className="divide-y divide-ink-100/70">{rows}</div>
    </section>
  );
}

function MochiSummary({ item }: { item: ResolvedItem }) {
  const original = item.ocrText ?? item.text;
  return (
    <section
      aria-label="모찌가 정리했어요"
      className="mt-4 rounded-3xl border border-ink-100 bg-surface p-6 shadow-card"
    >
      <h2 className="flex items-center gap-2 text-[13px] font-bold text-ink-500">
        <Image src="/brand/mochi2.png" alt="" width={20} height={20} aria-hidden />
        모찌가 정리했어요
      </h2>
      <p className="mt-3 text-[15.5px] leading-relaxed text-ink-900 [text-wrap:pretty]">
        {item.summary}
      </p>
      {original && (
        <blockquote className="mt-4 border-l-[3px] border-purple-200 pl-4 text-[13.5px] leading-relaxed text-ink-500">
          {original}
        </blockquote>
      )}
      {item.userMemo && (
        <p className="mt-4 rounded-xl bg-butter-50 px-4 py-3 text-[14px] font-medium text-[#6b5210]">
          내 메모 — {item.userMemo}
        </p>
      )}
    </section>
  );
}
