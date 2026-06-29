"use client";

import { motion, useReducedMotion } from "framer-motion";
import { MochiSprite, PillButton } from "@/components/ui";
import { CoverflowCSS } from "@/components/CoverflowCSS";

/* ─────────────────────────────────────────────────────────────
   Hero — 단일 영웅 경로의 첫 화면.
   왼쪽: "이거… 뭐였지?" → "아, 맞다." 헤드라인 + 부제 + CTA 2개.
   오른쪽: CSS 3D 코버플로우(CoverflowCSS) — DOM 카드라 텍스트·이미지가 또렷하고
   SSR/CSR 이 동일(스왑/하이드레이션 불일치 없음). reduced-motion 은 globals 가 처리.
   ───────────────────────────────────────────────────────────── */

function scrollTo(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
}

export function Hero() {
  const reduce = useReducedMotion();
  const ease = [0.16, 1, 0.3, 1] as const;
  const rise = reduce
    ? {}
    : { initial: { opacity: 0, y: 18 }, animate: { opacity: 1, y: 0 } };

  return (
    <section id="top" className="relative overflow-hidden px-5 pt-20 pb-12 sm:pt-28">
      <div className="mx-auto grid max-w-6xl items-center gap-10 md:grid-cols-[1.05fr_1fr] md:gap-6">
        {/* ── 카피 ── */}
        <div className="relative z-10 max-w-xl">
          <motion.p
            {...rise}
            transition={{ duration: 0.5, ease }}
            className="mb-5 inline-flex items-center gap-2 rounded-full border border-black/5 bg-white/60 px-3 py-1 text-xs font-semibold tracking-tight text-ink-500 backdrop-blur-md"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-purple-400" />
            놓치기 쉬운 순간을, 모찌가 먼저
          </motion.p>

          <motion.h1
            {...rise}
            transition={{ duration: 0.6, ease, delay: 0.05 }}
            className="text-balance text-4xl font-black leading-[1.04] tracking-tight text-ink-900 sm:text-5xl md:text-6xl"
          >
            <span className="text-ink-300">이거… 뭐였지?</span>
            <br />
            <span className="relative inline-block">
              아, 맞다.
              <motion.span
                aria-hidden
                className="absolute -bottom-1 left-0 h-3 w-full rounded-full bg-purple-100"
                initial={reduce ? false : { scaleX: 0 }}
                animate={reduce ? {} : { scaleX: 1 }}
                transition={{ duration: 0.7, ease, delay: 0.5 }}
                style={{ originX: 0, zIndex: -1 }}
              />
            </span>
          </motion.h1>

          <motion.p
            {...rise}
            transition={{ duration: 0.6, ease, delay: 0.12 }}
            className="mt-6 max-w-md text-pretty text-base leading-relaxed text-ink-500 sm:text-lg"
          >
            스크린샷·링크·메모를 담아두면 모찌가 알아서 분류하고 정리합니다. 다시
            찾아 헤맬 필요 없이, 필요한 순간에 먼저 떠올려 줍니다.
          </motion.p>

          <motion.div
            {...rise}
            transition={{ duration: 0.6, ease, delay: 0.18 }}
            className="mt-8 flex flex-wrap items-center gap-3"
          >
            <PillButton onClick={() => scrollTo("live")}>직접 해보기</PillButton>
            <PillButton variant="ghost" onClick={() => scrollTo("story-save")}>
              어떻게 되는지
            </PillButton>
          </motion.div>
        </div>

        {/* ── 코버플로우 ── */}
        <motion.div
          initial={reduce ? false : { opacity: 0, scale: 0.96 }}
          animate={reduce ? {} : { opacity: 1, scale: 1 }}
          transition={{ duration: 0.8, ease, delay: 0.2 }}
          className="relative h-[400px] w-full sm:h-[480px] md:h-[520px]"
        >
          <CoverflowCSS />

          {/* 모찌 — 한 켠에 살짝 (과하지 않게) */}
          <MochiSprite
            pose="peek"
            size={88}
            className="pointer-events-none absolute -bottom-1 right-1 z-[120] drop-shadow-[0_8px_16px_rgba(23,23,41,0.12)]"
          />
        </motion.div>
      </div>
    </section>
  );
}
