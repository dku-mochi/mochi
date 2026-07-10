"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowUpRight, X } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import { findItem } from "@/lib/seedRuntime";
import { ReasonChip } from "@/components/primitives/ReasonChip";

/*
 * 홈 진입 스포트라이트 — 리마인드(클라이맥스)를 여정 초반에 심는 한 번의 순간.
 * 사용자가 찾기 전에 모찌가 먼저 말을 건다. 세션당 1회, 닫으면 다시 나오지 않는다.
 * 우하단은 JourneyRail 자리라 좌하단에 도킹, 모바일은 생략(데스크톱 심사 동선 전용).
 */

const seenKey = (slug: string) => `mochi-spotlight-${slug}`;

export function RecallSpotlight() {
  const { persona, items } = usePersona();
  const reduce = useReducedMotion();
  const [visible, setVisible] = useState(false);

  const entry = persona.recall[0];
  const item = entry ? findItem(items, entry.itemSlug) : undefined;

  useEffect(() => {
    if (!entry || !item) return;
    if (sessionStorage.getItem(seenKey(persona.slug))) return;
    // 홈이 먼저 자리 잡은 뒤에 조용히 등장 — 헤드라인과 시선을 다투지 않는다.
    // seen 은 표시 시점에 기록 — 다른 씬에 다녀와도 같은 세션에선 다시 뜨지 않는다.
    const t = setTimeout(() => {
      sessionStorage.setItem(seenKey(persona.slug), "1");
      setVisible(true);
    }, reduce ? 400 : 1400);
    return () => clearTimeout(t);
  }, [entry, item, persona.slug, reduce]);

  const dismiss = () => setVisible(false);

  if (!entry || !item) return null;

  return (
    <AnimatePresence>
      {visible && (
        <motion.aside
          className="fixed bottom-5 left-5 z-40 hidden w-[330px] lg:block"
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 22, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={{ opacity: 0, y: 8, transition: { duration: 0.18 } }}
          transition={{ type: "spring", duration: 0.55, bounce: 0.24 }}
          aria-label="모찌가 먼저 떠올린 기록"
        >
          <div className="relative rounded-2xl border border-ink-100/80 bg-surface/95 p-4 shadow-card-lift backdrop-blur-xl">
            <button
              onClick={dismiss}
              aria-label="닫기"
              className="absolute right-2.5 top-2.5 flex size-7 items-center justify-center rounded-full text-ink-300 transition-colors hover:bg-ink-100/70 hover:text-ink-700"
            >
              <X className="size-3.5" aria-hidden />
            </button>
            <div className="flex items-start gap-3">
              <Image
                src="/brand/mochi2.png"
                alt=""
                width={36}
                height={36}
                className="mt-0.5 flex-none"
              />
              <div className="min-w-0 pr-5">
                <p className="text-[11.5px] font-bold text-purple-600">
                  모찌가 먼저 떠올렸어요
                </p>
                <p className="mt-1.5 text-[14px] font-bold leading-snug text-ink-900">
                  {entry.oneline}
                </p>
                <div className="mt-2.5 flex items-center gap-2">
                  <ReasonChip kind={entry.kind} />
                </div>
                <Link
                  href={`/p/${persona.slug}/items/${item.slug}`}
                  className="mt-3 inline-flex h-9 items-center gap-1 rounded-full bg-ink-900 px-4 text-[12.5px] font-bold text-white transition-transform active:scale-[0.97]"
                >
                  열어보기 <ArrowUpRight className="size-3.5" aria-hidden />
                </Link>
              </div>
            </div>
          </div>
        </motion.aside>
      )}
    </AnimatePresence>
  );
}
