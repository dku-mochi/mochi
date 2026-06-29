"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import Image from "next/image";
import { Sparkles } from "lucide-react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/dist/ScrollTrigger";
import { Eyebrow, GlassCard, ReasonChip, BehaviorMark, MochiSprite } from "@/components/ui";
import { RECALL_CARDS } from "@/seed/samples";
import type { RecallCard } from "@/lib/types";
import { cn } from "@/lib/cn";

// ─────────────────────────────────────────────────────────────
// Recall — 타임머신/떠오름.
// 스크롤 = 시간. "방금 저장" → "3주 뒤"로 시간이 흐르며 회수 카드가
// 하나씩 surface 된다. 각 카드는 ReasonChip 으로 "왜 지금 떠올랐는지"
// 규칙(마감/decay/유사도)을 증명한다 — 가짜 알림 연극이 아니라 규칙.
//
// reduced-motion / WebGL 무관 graceful: ScrollTrigger 없이 세로 나열.
// ─────────────────────────────────────────────────────────────

/** daysAgo → 시간축 위 라벨. 시간이 "흘러" 카드가 떠오른다는 감각. */
function elapsedLabel(daysAgo: number): string {
  if (daysAgo <= 0) return "방금 저장";
  if (daysAgo < 7) return `${daysAgo}일 뒤`;
  const weeks = Math.round(daysAgo / 7);
  return `${weeks}주 뒤`;
}

/** prefers-reduced-motion 구독 — SSR snapshot 은 true(정적 폴백). */
function useReducedMotion(): boolean {
  const subscribe = useCallback((cb: () => void) => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    mq.addEventListener("change", cb);
    return () => mq.removeEventListener("change", cb);
  }, []);
  return useSyncExternalStore(
    subscribe,
    () => window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    () => true,
  );
}

export function Timemachine({ cards = RECALL_CARDS }: { cards?: RecallCard[] }) {
  const [data, setData] = useState<RecallCard[]>(cards);
  const reduced = useReducedMotion();

  const rootRef = useRef<HTMLDivElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const railRef = useRef<HTMLDivElement>(null);
  const cardRefs = useRef<(HTMLDivElement | null)[]>([]);

  // 라이브 /api/recall 시도 → 실패 시 props/seed 폴백.
  useEffect(() => {
    let alive = true;
    fetch("/api/recall")
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((rows: RecallCard[]) => {
        if (alive && Array.isArray(rows) && rows.length > 0) setData(rows);
      })
      .catch(() => {
        /* props/seed 폴백 유지 */
      });
    return () => {
      alive = false;
    };
  }, []);

  // GSAP pinned scrub 타임라인 — data/reduced 변할 때마다 재구성.
  useEffect(() => {
    if (reduced) return;
    const track = trackRef.current;
    const root = rootRef.current;
    if (!track || !root) return;

    gsap.registerPlugin(ScrollTrigger);

    const ctx = gsap.context(() => {
      const cardEls = cardRefs.current.filter(Boolean) as HTMLDivElement[];
      if (cardEls.length === 0) return;

      // 시작 상태: 카드는 아래에서 흐릿하게 가라앉아 있음.
      gsap.set(cardEls, { autoAlpha: 0, y: 56, scale: 0.94 });
      if (railRef.current) gsap.set(railRef.current, { scaleY: 0, transformOrigin: "top" });

      const tl = gsap.timeline({
        defaults: { ease: "power2.out" },
        scrollTrigger: {
          trigger: root,
          start: "top top",
          // 카드 수에 비례해 스크롤 길이 확보(시간이 충분히 "흐르"도록).
          end: () => `+=${Math.max(1, cardEls.length) * 70}%`,
          pin: track,
          scrub: 0.8,
          anticipatePin: 1,
        },
      });

      // 시간축(레일)은 전체 타임라인에 걸쳐 채워진다.
      if (railRef.current) {
        tl.to(railRef.current, { scaleY: 1, ease: "none", duration: cardEls.length }, 0);
      }

      // 각 카드가 자기 "시간"에 도달하면 떠오른다(surface).
      cardEls.forEach((el, i) => {
        tl.to(
          el,
          { autoAlpha: 1, y: 0, scale: 1, duration: 0.6 },
          i, // 1단위 = 카드 한 칸의 시간
        );
        // 다음 카드 등장 직전, 이전 카드는 살짝 뒤로 물러나 깊이감.
        if (i < cardEls.length - 1) {
          tl.to(el, { scale: 0.97, y: -10, duration: 0.4 }, i + 0.6);
        }
      });
    }, root);

    return () => ctx.revert();
  }, [reduced, data]);

  // ── reduced-motion / SSR 폴백: 세로 나열 + ReasonChip ──────────
  if (reduced) {
    return (
      <section id="recall" className="scroll-mt-24 px-5 py-24 sm:py-28 md:py-32">
        <div className="mx-auto max-w-5xl">
          <Header />
          <div className="mt-12 flex flex-col gap-5">
            {data.map((card) => (
              <RecallRow key={card.id} card={card} static />
            ))}
          </div>
        </div>
      </section>
    );
  }

  // ── 모션 버전: pin + scrub 타임라인 ───────────────────────────
  return (
    <section id="recall" ref={rootRef} className="scroll-mt-24 px-5">
      <div ref={trackRef} className="flex min-h-screen flex-col justify-center py-20">
        <div className="mx-auto w-full max-w-5xl">
          <Header />

          <div className="mt-12 grid gap-x-8 gap-y-6 md:grid-cols-[auto_1fr]">
            {/* 시간축 레일 (md 이상) */}
            <div className="relative hidden w-px justify-self-center bg-black/5 md:block">
              <div
                ref={railRef}
                className="absolute inset-0 w-px bg-gradient-to-b from-purple-400 via-mint-400 to-peach-400"
              />
            </div>

            <div className="flex flex-col gap-6">
              {data.map((card, i) => (
                <div
                  key={card.id}
                  ref={(el) => {
                    cardRefs.current[i] = el;
                  }}
                >
                  <RecallRow card={card} />
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

/* ── 섹션 헤더 (양쪽 버전 공유) ─────────────────────────────── */
function Header() {
  return (
    <header className="max-w-3xl">
      <div className="mb-4 flex items-center gap-3">
        <Eyebrow tint="purple">Recall</Eyebrow>
        <MochiSprite pose="peek" size={36} className="translate-y-0.5" />
      </div>
      <h2 className="text-balance text-3xl font-black tracking-tight text-ink-900 sm:text-4xl md:text-5xl">
        시간이 지나면, 모찌가 먼저 꺼냅니다
      </h2>
      <p className="mt-5 text-pretty text-base leading-relaxed text-ink-500 sm:text-lg">
        담을 땐 그냥 담아요. 필요한 순간이 되면 — 마감이 다가오거나, 한참 안 봤거나,
        요즘 담는 것들과 결이 닿을 때 — 그 기록이 알아서 떠오릅니다.
      </p>
    </header>
  );
}

/* ── 회수 카드 한 줄 ──────────────────────────────────────────
   왼쪽 시간 마커 + GlassCard(캡처/제목/한 줄 + BehaviorMark + ReasonChip).
   ───────────────────────────────────────────────────────────── */
function RecallRow({ card, static: isStatic }: { card: RecallCard; static?: boolean }) {
  return (
    <div className="flex items-stretch gap-4">
      {/* 시간 마커 */}
      <div className="hidden w-16 shrink-0 flex-col items-end pt-1 text-right sm:flex">
        <span className="text-xs font-bold tracking-tight text-ink-900">
          {elapsedLabel(card.daysAgo)}
        </span>
        <span className="mt-0.5 text-[10px] font-medium text-ink-300">
          저장 후 {card.daysAgo}일
        </span>
      </div>

      <GlassCard
        className={cn(
          "flex-1 overflow-hidden",
          isStatic && "transition-shadow hover:shadow-float",
        )}
      >
        <div className="flex gap-4 p-4 sm:p-5">
          {/* 실제 캡처 썸네일 (있으면) */}
          {card.imageUrl ? (
            <div className="relative h-20 w-20 shrink-0 overflow-hidden rounded-md border border-black/5 bg-canvas sm:h-24 sm:w-24">
              <Image
                src={card.imageUrl}
                alt=""
                fill
                sizes="96px"
                aria-hidden
                draggable={false}
                className="object-cover"
              />
            </div>
          ) : (
            <div className="grid h-20 w-20 shrink-0 place-items-center rounded-md border border-black/5 bg-white/60 sm:h-24 sm:w-24">
              <BehaviorMark intent={card.intents[0] ?? "memo"} size="lg" />
            </div>
          )}

          <div className="flex min-w-0 flex-1 flex-col">
            <div className="flex items-start justify-between gap-3">
              <h3 className="text-balance text-base font-bold tracking-tight text-ink-900 sm:text-lg">
                {card.title}
              </h3>
              <div className="flex shrink-0 items-center gap-1.5">
                {card.intents.slice(0, 2).map((intent) => (
                  <BehaviorMark key={intent} intent={intent} size="sm" />
                ))}
              </div>
            </div>

            <p className="mt-1 line-clamp-2 text-sm leading-relaxed text-ink-500">
              {card.oneline}
            </p>

            {/* ★ 왜 지금 떠올랐는지 — 규칙의 증명 */}
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <ReasonChip reason={card.reason} />
              <span className="inline-flex items-center gap-1 text-xs text-ink-300">
                <Sparkles className="h-3 w-3" strokeWidth={2.2} />
                {card.reason.detail}
              </span>
            </div>
          </div>
        </div>
      </GlassCard>
    </div>
  );
}
