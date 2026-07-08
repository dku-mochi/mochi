"use client";

import Image from "next/image";
import { useMemo, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowRight, BookOpen, Check, Link2, Send } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import { kstParts, dday, type ResolvedItem } from "@/lib/seedRuntime";
import { useLiveAnalysis, STAGE_LABEL } from "@/lib/hooks/useLiveAnalysis";
import { ToolStatusPill } from "@/components/primitives/ToolStatusPill";
import { RiseIn } from "@/components/primitives/RiseIn";
import { domainOf } from "@/components/tiles/ItemTile";
import { cn } from "@/lib/cn";

/*
 * S2 기록 씬 — "캡처는 0노력, 정리는 자동".
 * 분류를 자랑하지 않는다: 카드가 체크리스트 행·캘린더 마감 점·지식 서랍으로
 * "꽂히는 행동"만 보여준다 (4-Intent 메타 비노출 원칙).
 * 마지막 스텝은 심사위원 직접 입력 → 진행 SSE → 같은 morph 로 착지.
 */

interface SortedTodo {
  key: string;
  label: string;
  dueAt?: number;
}
interface SortedDot {
  key: string;
  day: number;
  month: number;
  title: string;
}
interface SortedKnowledge {
  key: string;
  title: string;
  domain?: string;
}

export function CaptureScene() {
  const { persona, items, now } = usePersona();
  const reduce = useReducedMotion();

  // 페르소나에서 시나리오 3건 도출 — 메모→할일 / 캡처→일정·마감 / 링크→지식
  const steps = useMemo(() => {
    const memo = items.find(
      (i) => i.kind === "memo" && i.instances.some((x) => x.intentType === "todo" && !x.done),
    );
    const shot = items.find(
      (i) => i.kind === "screenshot" && i.instances.some((x) => x.intentType === "schedule"),
    );
    const link = items.find(
      (i) => i.kind === "url" && i.instances.some((x) => x.intentType === "knowledge"),
    );
    return [memo, shot, link].filter((x): x is ResolvedItem => Boolean(x));
  }, [items]);

  const [done, setDone] = useState(0); // 정리 완료된 스텝 수
  const [saving, setSaving] = useState(false); // "기억했어요!" 토스트 중
  const live = useLiveAnalysis(persona.slug);

  const allSorted = done >= steps.length;
  const current = steps[done];

  // 목적지 패널 내용 — 완료된 스텝 + 라이브 결과에서 파생
  const { todos, dots, knowledge } = useMemo(() => {
    const todos: SortedTodo[] = [];
    const dots: SortedDot[] = [];
    const knowledge: SortedKnowledge[] = [];
    for (const item of steps.slice(0, done)) {
      for (const inst of item.instances) {
        if (inst.intentType === "todo" && !inst.done) {
          todos.push({
            key: `${item.slug}-t`,
            label: inst.payload?.title ?? inst.label ?? item.title,
            dueAt: inst.dueAt,
          });
        }
        if (inst.intentType === "schedule" && inst.dueAt) {
          const p = kstParts(inst.dueAt);
          dots.push({
            key: `${item.slug}-s`,
            day: p.day,
            month: p.month,
            title: inst.payload?.title ?? item.title,
          });
        }
        if (inst.intentType === "knowledge") {
          knowledge.push({
            key: `${item.slug}-k`,
            title: item.title,
            domain: domainOf(item.url),
          });
        }
      }
    }
    if (live.result) {
      for (const [i, intent] of live.result.intents.entries()) {
        const key = `live-${i}`;
        if (intent.intentType === "todo")
          todos.push({
            key,
            label: intent.label ?? live.result.title,
            dueAt: intent.deadline
              ? Date.parse(`${intent.deadline}T00:00:00+09:00`)
              : undefined,
          });
        if (intent.intentType === "schedule" && intent.date) {
          const [, m, d] = intent.date.split("-").map(Number);
          dots.push({ key, day: d, month: m, title: intent.label ?? live.result.title });
        }
        if (intent.intentType === "knowledge")
          knowledge.push({ key, title: live.result.title });
        if (intent.intentType === "memo" && live.result.intents.length === 1)
          knowledge.push({ key, title: live.result.title });
      }
    }
    return { todos, dots, knowledge };
  }, [steps, done, live.result]);

  const sendCurrent = () => {
    if (!current || saving) return;
    setSaving(true);
    setTimeout(() => {
      setSaving(false);
      setDone((d) => d + 1);
    }, reduce ? 250 : 1050);
  };

  return (
    <main className="mx-auto grid max-w-6xl grid-cols-1 gap-8 px-5 py-8 lg:grid-cols-12">
      {/* ── 좌: 캡처 무대 ── */}
      <div className="lg:col-span-5">
        <RiseIn index={0}>
          <h1 className="font-display text-[24px] tracking-head">
            보내기만 하세요
          </h1>
          <p className="mt-1.5 text-[14px] leading-relaxed text-ink-500">
            스크린샷·링크·메모가 들어오면, 모찌가 할 일과 마감으로 만들어 제자리에
            꽂아둡니다.
          </p>
        </RiseIn>

        <RiseIn index={1}>
          <div className="relative mt-5 flex min-h-[380px] flex-col items-center justify-center rounded-3xl border border-ink-100 bg-surface p-6 shadow-card">
            <AnimatePresence mode="wait">
              {!allSorted && current ? (
                <motion.div
                  key={current.slug}
                  initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.92, y: 18 }}
                  animate={{ opacity: 1, scale: 1, y: 0 }}
                  exit={
                    reduce
                      ? { opacity: 0 }
                      : { opacity: 0, x: 120, scale: 0.6, transition: { duration: 0.4 } }
                  }
                  transition={{ type: "spring", duration: 0.55, bounce: 0.24 }}
                  className="w-full max-w-[280px]"
                >
                  <StageCard item={current} />
                  <button
                    onClick={sendCurrent}
                    disabled={saving}
                    className="mt-5 flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-gradient-to-r from-purple-400 to-purple-600 text-[15px] font-bold text-white shadow-fab transition-transform active:scale-[0.97] disabled:opacity-70"
                  >
                    <Send className="size-4" aria-hidden /> 모찌에게 보내기
                  </button>
                  <p className="mt-2.5 text-center text-[12px] text-ink-300 tnum">
                    {done + 1} / {steps.length} · {current.source}
                  </p>
                </motion.div>
              ) : (
                <LivePanel key="live" live={live} />
              )}
            </AnimatePresence>

            {/* "기억했어요!" 저장 모먼트 (ShareExtension 이식) */}
            <AnimatePresence>
              {saving && (
                <motion.div
                  className="absolute inset-0 z-10 flex flex-col items-center justify-center rounded-3xl bg-surface/85 backdrop-blur-sm"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                >
                  <motion.div
                    initial={reduce ? {} : { scale: 0.5, y: 22 }}
                    animate={{ scale: 1, y: 0 }}
                    transition={{ type: "spring", duration: 0.55, bounce: 0.55 }}
                  >
                    <Image
                      src="/brand/mochi-cheer.png"
                      alt=""
                      width={96}
                      height={96}
                      className="h-[84px] w-auto drop-shadow-[0_10px_24px_rgba(139,108,255,0.35)]"
                    />
                  </motion.div>
                  <p className="mt-3 font-display text-[20px] tracking-head text-purple-600">
                    기억했어요!
                  </p>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </RiseIn>

        {!allSorted && (
          <RiseIn index={2}>
            <button
              onClick={() => setDone(steps.length)}
              className="mt-3 inline-flex items-center gap-1 text-[13px] font-semibold text-ink-500 transition-colors hover:text-ink-900"
            >
              결과만 보기 <ArrowRight className="size-3.5" aria-hidden />
            </button>
          </RiseIn>
        )}
      </div>

      {/* ── 우: 목적지 3패널 ── */}
      <div className="space-y-4 lg:col-span-7">
        <RiseIn index={2}>
          <DestTodos todos={todos} now={now} />
        </RiseIn>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <RiseIn index={3}>
            <DestCalendar dots={dots} now={now} />
          </RiseIn>
          <RiseIn index={4}>
            <DestKnowledge entries={knowledge} />
          </RiseIn>
        </div>
      </div>
    </main>
  );
}

/* 무대 위 캡처 카드 — 소스별 3변형 */
function StageCard({ item }: { item: ResolvedItem }) {
  if (item.kind === "screenshot" && item.image) {
    return (
      <div className="overflow-hidden rounded-2xl shadow-card-lift ring-1 ring-black/10">
        <Image
          src={item.image.file}
          alt={item.title}
          width={item.image.width}
          height={item.image.height}
          className="max-h-[240px] w-full object-cover object-top"
        />
      </div>
    );
  }
  if (item.kind === "url") {
    return (
      <div className="rounded-2xl bg-purple-50 p-5 ring-1 ring-inset ring-purple-100">
        <span className="flex size-10 items-center justify-center rounded-xl bg-surface shadow-card">
          <Link2 className="size-4.5 text-purple-500" aria-hidden />
        </span>
        <p className="mt-3 text-[15px] font-bold leading-snug">{item.title}</p>
        <p className="mt-1.5 truncate text-[12px] font-medium text-purple-600/80">
          {domainOf(item.url)}
        </p>
      </div>
    );
  }
  return (
    <div className="rounded-2xl bg-butter-50 p-5 ring-1 ring-inset ring-butter-100">
      <p className="text-[12px] font-bold text-[#8A6410]">{item.source}</p>
      <p className="mt-2 text-[15px] font-semibold leading-relaxed text-ink-900">
        “{item.text ?? item.title}”
      </p>
    </div>
  );
}

/* 라이브 스텝 — 심사위원 직접 입력 → 진행 SSE → 착지 */
function LivePanel({
  live,
}: {
  live: ReturnType<typeof useLiveAnalysis>;
}) {
  const [value, setValue] = useState("");
  const running =
    live.stage !== "idle" && live.stage !== "done" && live.stage !== "failed";

  return (
    <motion.div
      className="w-full max-w-[300px] text-center"
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ type: "spring", duration: 0.5, bounce: 0.15 }}
    >
      <Image
        src="/brand/mochi-hello.png"
        alt=""
        width={72}
        height={72}
        className="mx-auto h-[60px] w-auto"
      />
      <h2 className="mt-3 text-[17px] font-extrabold tracking-snug">
        이번엔 직접 보내보세요
      </h2>
      <p className="mt-1 text-[12.5px] leading-relaxed text-ink-500">
        해야 할 일이나 약속을 한 줄로 — 링크도 좋아요
      </p>

      {running ? (
        <div className="mt-5 flex justify-center">
          <ToolStatusPill
            label={STAGE_LABEL[live.stage as keyof typeof STAGE_LABEL] ?? "정리하고 있어요…"}
          />
        </div>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (!value.trim()) return;
            const isUrl = /^https?:\/\//.test(value.trim());
            void live.run(isUrl ? { url: value.trim() } : { text: value.trim() });
          }}
          className="mt-4"
        >
          <input
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="예: 금요일 3시 팀 미팅 준비하기"
            aria-label="모찌에게 보낼 내용"
            className="w-full rounded-2xl border border-ink-100 bg-bg/60 px-4 py-3 text-center text-[14px] outline-none placeholder:text-ink-300 focus:border-purple-200"
          />
          <button
            type="submit"
            disabled={!value.trim()}
            className="mt-3 flex h-11 w-full items-center justify-center gap-2 rounded-2xl bg-gradient-to-r from-purple-400 to-purple-600 text-[14px] font-bold text-white shadow-fab transition-transform active:scale-[0.97] disabled:opacity-50"
          >
            <Send className="size-4" aria-hidden /> 모찌에게 보내기
          </button>
        </form>
      )}

      {live.stage === "done" && live.result && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          className="mt-4 rounded-2xl bg-mint-100/60 p-4 text-left"
        >
          <p className="flex items-center gap-1.5 text-[12.5px] font-bold text-[#187A4E]">
            <Check className="size-3.5" strokeWidth={3} aria-hidden />
            정리해서 꽂아뒀어요 →
          </p>
          <p className="mt-1.5 text-[13px] leading-relaxed text-ink-700">
            {live.result.summary}
          </p>
          <button
            onClick={live.reset}
            className="mt-2.5 text-[12px] font-semibold text-ink-500 underline-offset-2 hover:underline"
          >
            하나 더 보내보기
          </button>
        </motion.div>
      )}
      {live.stage === "failed" && (
        <p className="mt-4 text-[13px] font-medium text-blush-400">
          잠시 고르지 않네요 — 다시 보내주세요.
          <button onClick={live.reset} className="ml-2 underline">
            다시
          </button>
        </p>
      )}
    </motion.div>
  );
}

/* ── 목적지 패널들 ── */

function DestTodos({ todos, now }: { todos: SortedTodo[]; now: number }) {
  return (
    <section
      aria-label="할 일로 정리됨"
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <h2 className="text-[15px] font-extrabold tracking-snug">할 일</h2>
      <ul className="mt-2.5 min-h-[52px] space-y-1">
        <AnimatePresence initial={false}>
          {todos.map((t) => (
            <motion.li
              key={t.key}
              layout
              initial={{ opacity: 0, x: -28, scale: 0.96 }}
              animate={{ opacity: 1, x: 0, scale: 1 }}
              transition={{ type: "spring", duration: 0.55, bounce: 0.3 }}
              className="flex items-center gap-3 rounded-xl bg-butter-50/70 px-3 py-2.5"
            >
              <span className="size-[18px] flex-none rounded-md border-[1.5px] border-butter-400 bg-surface" />
              <span className="min-w-0 flex-1 truncate text-[13.5px] font-semibold">
                {t.label}
              </span>
              {t.dueAt !== undefined && (
                <span className="flex-none rounded-full bg-butter-100 px-2 py-0.5 text-[11px] font-bold text-[#8A6410] tnum">
                  {dday(t.dueAt, now)}
                </span>
              )}
            </motion.li>
          ))}
        </AnimatePresence>
        {todos.length === 0 && (
          <li className="py-3 text-center text-[12.5px] text-ink-300">
            보내면 여기에 할 일이 생겨요
          </li>
        )}
      </ul>
    </section>
  );
}

function DestCalendar({ dots, now }: { dots: SortedDot[]; now: number }) {
  const { year, month, day: today } = kstParts(now);
  const first = new Date(Date.UTC(year, month - 1, 1)).getUTCDay();
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const cells: Array<number | null> = [
    ...Array.from({ length: first }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) => i + 1),
  ];
  const dotDays = new Map<number, SortedDot>();
  for (const d of dots) if (d.month === month) dotDays.set(d.day, d);

  return (
    <section
      aria-label="캘린더에 올라감"
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <h2 className="text-[15px] font-extrabold tracking-snug">{month}월</h2>
      <div className="mt-2.5 grid grid-cols-7 gap-y-0.5 text-center">
        {["일", "월", "화", "수", "목", "금", "토"].map((w) => (
          <span key={w} className="text-[10px] font-semibold text-ink-300">
            {w}
          </span>
        ))}
        {cells.map((day, i) => (
          <div key={i} className="flex h-8 flex-col items-center pt-0.5">
            {day && (
              <>
                <span
                  className={cn(
                    "flex size-[22px] items-center justify-center rounded-full text-[11px] font-semibold tnum",
                    day === today ? "bg-purple-500 text-white" : "text-ink-700",
                  )}
                >
                  {day}
                </span>
                <AnimatePresence>
                  {dotDays.has(day) && (
                    <motion.i
                      initial={{ scale: 0 }}
                      animate={{ scale: 1 }}
                      transition={{ type: "spring", duration: 0.5, bounce: 0.6 }}
                      className="mt-0.5 size-[5px] rounded-full bg-sky-400"
                      aria-label={dotDays.get(day)!.title}
                    />
                  )}
                </AnimatePresence>
              </>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}

function DestKnowledge({ entries }: { entries: SortedKnowledge[] }) {
  return (
    <section
      aria-label="지식으로 보관됨"
      className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card"
    >
      <h2 className="text-[15px] font-extrabold tracking-snug">서재</h2>
      <ul className="mt-2.5 min-h-[52px] space-y-1.5">
        <AnimatePresence initial={false}>
          {entries.map((k) => (
            <motion.li
              key={k.key}
              layout
              initial={{ opacity: 0, y: 14, scale: 0.96 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              transition={{ type: "spring", duration: 0.55, bounce: 0.3 }}
              className="flex items-center gap-2.5 rounded-xl bg-mint-100/50 px-3 py-2.5"
            >
              <BookOpen className="size-4 flex-none text-mint-400" aria-hidden />
              <span className="min-w-0 flex-1 truncate text-[13px] font-semibold">
                {k.title}
              </span>
              {k.domain && (
                <span className="flex-none text-[11px] text-ink-500">{k.domain}</span>
              )}
            </motion.li>
          ))}
        </AnimatePresence>
        {entries.length === 0 && (
          <li className="py-3 text-center text-[12.5px] text-ink-300">
            링크와 배움은 여기 쌓여요
          </li>
        )}
      </ul>
    </section>
  );
}
