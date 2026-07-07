"use client";

import dynamic from "next/dynamic";
import Link from "next/link";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { ArrowUpRight } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import { findItem, type ResolvedItem } from "@/lib/seedRuntime";
import { snapTarget, circularOffset } from "@/lib/coverflowMath";
import { ReasonChip, REASON_META } from "@/components/primitives/ReasonChip";
import type { DeckHandle } from "./CoverflowCanvas";
import { RecallFallback } from "./RecallFallback";
import { cn } from "@/lib/cn";

const CoverflowCanvas = dynamic(() => import("./CoverflowCanvas"), {
  ssr: false,
});

/* 픽셀당 회전 감도 — 한 카드에 약 260px */
const STEP_PX = 260;

export function RecallScene() {
  const { persona, items } = usePersona();
  const reduce = useReducedMotion();

  const entries = persona.recall;
  const deckItems = useMemo(
    () =>
      entries
        .map((e) => findItem(items, e.itemSlug))
        .filter((x): x is ResolvedItem => Boolean(x)),
    [entries, items],
  );

  const [phase, setPhase] = useState<"interstitial" | "stage">("interstitial");
  const [focal, setFocal] = useState(0);
  const [webgl, setWebgl] = useState<boolean | null>(null);

  // 진입 연출 — iOS 첫 진입처럼 한 칸 굴러 들어온다
  const deck = useRef<DeckHandle>({ rotation: -0.85, target: 0, dragging: false });
  const drag = useRef({ startX: 0, startRot: 0, lastX: 0, lastT: 0, vel: 0 });
  const wheelLock = useRef(0);

  useEffect(() => {
    // 마운트 후 1회 WebGL 프로브 — SSR 에서는 document 가 없어 lazy init 불가
    try {
      const c = document.createElement("canvas");
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setWebgl(Boolean(c.getContext("webgl2") ?? c.getContext("webgl")));
    } catch {
      setWebgl(false);
    }
  }, []);

  useEffect(() => {
    if (phase !== "interstitial") return;
    // reduce-motion 사용자는 비필수 시간 연출을 건너뛴다
    const t = setTimeout(() => setPhase("stage"), reduce ? 0 : 2200);
    return () => clearTimeout(t);
  }, [phase, reduce]);

  const goTo = useCallback(
    (index: number) => {
      const d = deck.current;
      d.target = Math.round(
        d.rotation + circularOffset(index, d.rotation, deckItems.length),
      );
    },
    [deckItems.length],
  );

  const step = useCallback((dir: 1 | -1) => {
    const d = deck.current;
    d.target = Math.round(d.rotation) + dir;
  }, []);

  if (deckItems.length === 0) return null;
  const entry = entries[focal];
  const meta = REASON_META[entry.kind];

  const useFallback = reduce || webgl === false;

  return (
    <main
      className="relative h-[calc(100dvh-57px)] min-h-[560px] overflow-hidden"
      aria-label="떠오름 — 모찌가 먼저 떠올린 기록"
    >
      {/* focalGlow — 덱 뒤 공간이 이유 색으로 물든다 (iOS 확장) */}
      <AnimatePresence initial={false}>
        <motion.div
          key={entry.kind}
          className="absolute inset-0"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.55, ease: "easeOut" }}
          style={{
            background: `radial-gradient(90% 65% at 50% 38%, ${meta.glow}55 0%, ${meta.glow}18 45%, transparent 72%),
                         radial-gradient(140% 90% at 50% 110%, ${meta.glow}22 0%, transparent 55%)`,
          }}
          aria-hidden
        />
      </AnimatePresence>

      <div className="relative z-10 flex h-full flex-col">
        <div className="mx-auto w-full max-w-6xl px-5 pt-6">
          <h1 className="font-display text-[22px] tracking-head">떠오름</h1>
          <p className="mt-1 text-[13.5px] font-medium text-ink-500">
            찾지 않아도 — 모찌가 이유와 함께 먼저 떠올려요
          </p>
        </div>

        {useFallback ? (
          <RecallFallback
            entries={entries}
            items={deckItems}
            focal={focal}
            onFocalChange={setFocal}
          />
        ) : (
          <div
            className="relative min-h-0 flex-1 cursor-grab touch-pan-y select-none active:cursor-grabbing"
            role="group"
            aria-roledescription="캐러셀"
            aria-label={`떠오른 기록 ${deckItems.length}개 중 ${focal + 1}번째: ${deckItems[focal].title}`}
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === "ArrowRight") step(1);
              if (e.key === "ArrowLeft") step(-1);
              if (e.key === "Enter")
                window.location.assign(
                  `/p/${persona.slug}/items/${deckItems[focal].slug}`,
                );
            }}
            onPointerDown={(e) => {
              const d = deck.current;
              e.currentTarget.setPointerCapture(e.pointerId);
              d.dragging = true;
              drag.current = {
                startX: e.clientX,
                startRot: d.rotation,
                lastX: e.clientX,
                lastT: performance.now(),
                vel: 0,
              };
            }}
            onPointerMove={(e) => {
              const d = deck.current;
              if (!d.dragging) return;
              const dr = drag.current;
              d.rotation = dr.startRot - (e.clientX - dr.startX) / STEP_PX;
              const t = performance.now();
              if (t - dr.lastT > 12) {
                dr.vel = (-(e.clientX - dr.lastX) / STEP_PX / (t - dr.lastT)) * 1000;
                dr.lastX = e.clientX;
                dr.lastT = t;
              }
            }}
            onPointerUp={() => {
              const d = deck.current;
              if (!d.dragging) return;
              d.dragging = false;
              d.target = snapTarget(d.rotation, drag.current.vel);
            }}
            onPointerCancel={() => {
              const d = deck.current;
              d.dragging = false;
              d.target = Math.round(d.rotation);
            }}
            onWheel={(e) => {
              const now = performance.now();
              if (now - wheelLock.current < 320) return;
              const delta = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
              if (Math.abs(delta) < 12) return;
              wheelLock.current = now;
              step(delta > 0 ? 1 : -1);
            }}
            onDoubleClick={() =>
              window.location.assign(`/p/${persona.slug}/items/${deckItems[focal].slug}`)
            }
          >
            {phase === "stage" && (
              <CoverflowCanvas
                items={deckItems}
                deck={deck}
                onFocalChange={setFocal}
              />
            )}
          </div>
        )}

        {/* 캡션 — 초점 카드의 "왜 지금" */}
        {!useFallback && (
          <div className="mx-auto w-full max-w-2xl px-5 pb-7 text-center">
            <AnimatePresence mode="wait" initial={false}>
              <motion.div
                key={focal}
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -6 }}
                transition={{ type: "spring", duration: 0.4, bounce: 0 }}
              >
                <ReasonChip kind={entry.kind} />
                <h2 className="mt-2.5 font-display text-[22px] leading-snug tracking-head [text-wrap:balance]">
                  {entry.oneline}
                </h2>
                <p className="mt-1.5 text-[13.5px] leading-relaxed text-ink-500">
                  {entry.gist.join(" · ")}
                </p>
                <Link
                  href={`/p/${persona.slug}/items/${deckItems[focal].slug}`}
                  className="mt-3.5 inline-flex h-10 items-center gap-1 rounded-full bg-ink-900 px-5 text-[13.5px] font-bold text-white shadow-card transition-transform active:scale-[0.97]"
                >
                  이 기록 열기 <ArrowUpRight className="size-4" aria-hidden />
                </Link>
              </motion.div>
            </AnimatePresence>

            <div className="mt-5 flex items-center justify-center gap-2" role="group" aria-label="떠오른 기록 선택">
              {deckItems.map((it, i) => (
                <button
                  key={it.slug}
                  aria-current={i === focal ? "true" : undefined}
                  aria-label={`${i + 1}번째: ${it.title}`}
                  onClick={() => goTo(i)}
                  className={cn(
                    "relative h-2 rounded-full transition-all duration-300 after:absolute after:-inset-2.5 after:content-['']",
                    i === focal ? "w-6 bg-ink-900" : "w-2 bg-ink-300 hover:bg-ink-500",
                  )}
                />
              ))}
            </div>
            <p className="mt-3 text-[11.5px] font-medium text-ink-300">
              드래그 · 휠 · ← → 로 넘기고, Enter 로 열기
            </p>
          </div>
        )}
      </div>

      {/* 타임 점프 인터스티셜 */}
      <AnimatePresence>
        {phase === "interstitial" && (
          <motion.button
            className="absolute inset-0 z-30 flex cursor-pointer items-center justify-center bg-ink-900"
            initial={{ opacity: 1 }}
            exit={{ opacity: 0, transition: { duration: 0.7, ease: "easeInOut" } }}
            onClick={() => setPhase("stage")}
            aria-label="건너뛰기"
          >
            <motion.p
              className="px-6 text-center font-display text-[26px] tracking-head text-white/90"
              initial={reduce ? { opacity: 0 } : { opacity: 0, y: 14 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.8, ease: "easeOut", delay: 0.15 }}
            >
              그리고 며칠 뒤 아침 —
            </motion.p>
          </motion.button>
        )}
      </AnimatePresence>
    </main>
  );
}
