"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { motion, useReducedMotion } from "framer-motion";
import { ArrowRight, Shuffle } from "lucide-react";
import type { IntentType, PersonaAccent } from "@seed/schema";
import { INTENT_META } from "@/components/primitives/IntentChip";
import { RiseIn } from "@/components/primitives/RiseIn";
import { cn } from "@/lib/cn";

/*
 * S1 페르소나 카드 3장 — 이름·페인포인트·대표 캡처 스택·intent 분포.
 * hover 시 캡처 스택이 부채꼴로 펼쳐진다.
 * 선택 → 여정 첫 씬(기록)으로, guided 모드 진입.
 */

export interface PersonaCardData {
  slug: string;
  name: string;
  age: number;
  job: string;
  tagline: string;
  intro: string;
  accent: PersonaAccent;
  heroImages: string[];
  byIntent: Record<IntentType, number>;
  itemCount: number;
}

const ACCENT_BG: Record<PersonaAccent, string> = {
  sky: "from-sky-100/80",
  butter: "from-butter-100/80",
  mint: "from-mint-100/80",
  blush: "from-blush-100/80",
  peach: "from-butter-100/80",
  purple: "from-purple-100/80",
};

/** 캡처 스택 기울기 — idle → hover 부채꼴 */
const FAN = [
  { idle: { rotate: -7, x: -34, y: 6 }, open: { rotate: -14, x: -66, y: 2 } },
  { idle: { rotate: 1, x: 0, y: 0 }, open: { rotate: 0, x: 0, y: -10 } },
  { idle: { rotate: 8, x: 34, y: 7 }, open: { rotate: 15, x: 66, y: 3 } },
];

const INTENT_ORDER: IntentType[] = ["schedule", "todo", "knowledge", "memo"];

function IntentBar({ byIntent, total }: { byIntent: Record<IntentType, number>; total: number }) {
  return (
    <div>
      <div
        className="flex h-2 overflow-hidden rounded-full bg-ink-100"
        role="img"
        aria-label={INTENT_ORDER.map(
          (t) => `${INTENT_META[t].label} ${byIntent[t]}건`,
        ).join(", ")}
      >
        {INTENT_ORDER.map((t) =>
          byIntent[t] > 0 ? (
            <span
              key={t}
              className={cn("h-full", INTENT_META[t].chip)}
              style={{ width: `${(byIntent[t] / total) * 100}%` }}
            />
          ) : null,
        )}
      </div>
      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1">
        {INTENT_ORDER.map((t) => {
          const meta = INTENT_META[t];
          return (
            <span key={t} className="inline-flex items-center gap-1 text-[11.5px] font-semibold text-ink-500">
              <meta.Icon className={cn("size-3", meta.dot)} strokeWidth={2.4} aria-hidden />
              {meta.label} <span className="tnum">{byIntent[t]}</span>
            </span>
          );
        })}
      </div>
    </div>
  );
}

function PersonaCard({ card, index }: { card: PersonaCardData; index: number }) {
  const reduce = useReducedMotion();

  const inner = (
    <motion.article
      className="group relative flex h-full flex-col overflow-hidden rounded-lg border border-ink-100 bg-surface shadow-card transition-shadow duration-300 hover:shadow-card-lift"
      initial="idle"
      whileHover={reduce ? undefined : "open"}
    >
      {/* 캡처 스택 무대 */}
      <div
        className={cn(
          "relative h-48 overflow-hidden bg-gradient-to-b to-surface",
          ACCENT_BG[card.accent],
        )}
        aria-hidden
      >
        <div className="absolute inset-x-0 top-7">
          {card.heroImages.map((src, i) => (
            <motion.div
              key={src}
              className="absolute w-[86px] overflow-hidden rounded-lg shadow-card ring-1 ring-black/10"
              /* absolute 라 flex 중앙정렬이 안 먹는다 — left 50% + 반폭 마진으로 축을 맞추고 x 는 framer 소관 */
              style={{ zIndex: i === 1 ? 2 : 1, left: "50%", marginLeft: -43 }}
              variants={{ idle: FAN[i]?.idle ?? {}, open: FAN[i]?.open ?? {} }}
              transition={{ type: "spring", duration: 0.45, bounce: 0.3 }}
            >
              {/* eslint-disable-next-line @next/next/no-img-element -- 장식 스택, 반응형 최적화 불필요 */}
              <img src={src} alt="" className="aspect-[0.47] w-full object-cover object-top" />
            </motion.div>
          ))}
        </div>
      </div>

      <div className="flex flex-1 flex-col p-5">
        <div className="flex items-baseline justify-between">
          <h2 className="font-display text-[20px] tracking-head">{card.name}</h2>
          <span className="text-[12.5px] font-medium text-ink-500">
            {card.age} · {card.job}
          </span>
        </div>
        <p className="mt-2.5 text-[15px] font-bold leading-snug text-ink-900 [text-wrap:balance]">
          “{card.tagline}”
        </p>
        <p className="mt-1.5 text-[13px] leading-relaxed text-ink-500">{card.intro}</p>

        <div className="mt-4">
          <IntentBar byIntent={card.byIntent} total={card.itemCount} />
        </div>

        <div className="mt-auto flex items-center justify-between pt-5">
          <span className="text-[12px] font-semibold text-ink-300">
            일주일치 기록 <span className="tnum text-ink-500">{card.itemCount}</span>건
          </span>
          <span className="inline-flex h-9 items-center gap-1 rounded-full bg-ink-900 px-4 text-[13px] font-bold text-white transition-transform group-hover:scale-[1.04]">
            이 사람으로 <ArrowRight className="size-3.5" aria-hidden />
          </span>
        </div>
      </div>
    </motion.article>
  );

  return (
    <RiseIn index={index + 1} className="h-full">
      <Link
        href={`/p/${card.slug}/capture?guided=1&new=1`}
        className="block h-full rounded-lg focus-visible:outline-2"
        aria-label={`${card.name} — ${card.tagline}. 이 사람으로 체험 시작`}
      >
        {inner}
      </Link>
    </RiseIn>
  );
}

export function PersonaSelect({ cards }: { cards: PersonaCardData[] }) {
  const router = useRouter();

  const pickRandom = () => {
    const pick = cards[Math.floor(Math.random() * cards.length)];
    router.push(`/p/${pick.slug}/capture?guided=1&new=1`);
  };

  return (
    <main className="relative min-h-dvh overflow-hidden">
      {/* 라벤더 → bg 로 가라앉는 무대 배경 */}
      <div
        className="absolute inset-x-0 top-0 h-[420px] bg-gradient-to-b from-lavender-200/70 to-transparent"
        aria-hidden
      />

      <div className="relative mx-auto max-w-6xl px-6 pb-20 pt-14">
        <RiseIn index={0}>
          <p className="text-center text-[13px] font-bold tracking-wide text-purple-500">
            모찌는 계정마다 다르게 일해요
          </p>
          <h1 className="mt-3 text-center font-display text-[clamp(24px,4vw,38px)] tracking-head [text-wrap:balance]">
            누구의 일주일로 체험할까요?
          </h1>
          <p className="mx-auto mt-3 max-w-xl text-center text-[14px] leading-relaxed text-ink-500">
            세 사람 모두 실제로 쌓인 일주일치 기록을 갖고 있어요.
            고른 사람의 기록으로 홈·검색·질문·리마인드까지 이어져요.
          </p>
        </RiseIn>

        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {cards.map((card, i) => (
            <PersonaCard key={card.slug} card={card} index={i} />
          ))}
        </div>

        <RiseIn index={5}>
          <div className="mt-10 flex justify-center">
            <button
              onClick={pickRandom}
              className="inline-flex h-11 items-center gap-2 rounded-full border border-ink-100 bg-surface px-5 text-[13.5px] font-semibold text-ink-700 shadow-card transition-transform hover:scale-[1.02] active:scale-[0.98]"
            >
              <Shuffle className="size-4 text-purple-500" aria-hidden />
              아무나 골라주세요
            </button>
          </div>
        </RiseIn>
      </div>
    </main>
  );
}
