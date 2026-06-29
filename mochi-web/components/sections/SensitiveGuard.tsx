"use client";

import { useEffect, useRef, useState } from "react";
import {
  motion,
  useInView,
  useReducedMotion,
  type Variants,
} from "framer-motion";
import { ScanLine, Lock, Sparkles, ShieldCheck } from "lucide-react";
import { Section, GlassCard } from "@/components/ui";
import { cn } from "@/lib/cn";

/* ─────────────────────────────────────────────────────────────
   민감 캡처 보호 — 정직-증거 원칙(codex).
   on-device 감지는 웹이 못 한다. 그래서 이 영역은 "앱에서 일어나는 일"의
   재현(reenactment)이며, 단정-증거가 아니라 정적 다이어그램 + 모션이다.
   실제 iOS 녹화 영상이 준비되면 아래 [영상 슬롯]을 video 로 교체한다.

   3단계 미니 플로우: 감지 → 마스킹 → 의미 보존.
   원본 "신한카드 1234-5678-9012-3456" 이 마스크로 덮이고
   "[카드: 신한카드 끝자리 3456]" 으로 의미만 남는다.
   (semantic-replace 규약: docs/PRIVACY_SENSITIVE_CAPTURE.md §2.1)
   ───────────────────────────────────────────────────────────── */

const ORIGINAL_LABEL = "신한카드";
const ORIGINAL_NUMBER = "1234-5678-9012-3456";
const PRESERVED = "[카드: 신한카드 끝자리 3456]";

type Step = {
  Icon: typeof ScanLine;
  title: string;
  body: string;
  tint: { wrap: string; icon: string };
};

const STEPS: Step[] = [
  {
    Icon: ScanLine,
    title: "감지",
    body: "단말이 화면 글자를 먼저 읽어 카드번호 같은 식별자를 가려낸다.",
    tint: { wrap: "bg-sky-100 ring-sky-400/25", icon: "text-sky-400" },
  },
  {
    Icon: Lock,
    title: "마스킹",
    body: "위험한 자리만 덮는다. 원본은 기기 밖으로 나가지 않는다.",
    tint: { wrap: "bg-peach-100 ring-peach-400/25", icon: "text-peach-400" },
  },
  {
    Icon: Sparkles,
    title: "의미 보존",
    body: "지우는 대신 뜻만 남긴다 — 검색도 분류도 그대로 작동한다.",
    tint: { wrap: "bg-mint-100 ring-mint-400/25", icon: "text-mint-400" },
  },
];

export function SensitiveGuard() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, margin: "-20% 0px" });

  // 마스킹 시퀀스: 카드가 화면에 들어오면 가림막이 덮이고, 이어서 의미보존 칩이 뜬다.
  const [masked, setMasked] = useState(false);
  const [preserved, setPreserved] = useState(false);

  useEffect(() => {
    if (!inView) return;
    if (reduce) {
      // 모션 없이 즉시 최종 상태(정적 폴백) — 의미는 동일하게 전달.
      setMasked(true);
      setPreserved(true);
      return;
    }
    const t1 = setTimeout(() => setMasked(true), 700);
    const t2 = setTimeout(() => setPreserved(true), 1500);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, [inView, reduce]);

  const stepVariants: Variants = {
    hidden: { opacity: 0, y: reduce ? 0 : 14 },
    show: (i: number) => ({
      opacity: 1,
      y: 0,
      transition: { delay: reduce ? 0 : 0.1 + i * 0.12, duration: 0.5, ease: "easeOut" },
    }),
  };

  return (
    <Section
      id="guard"
      eyebrow={{ tint: "mint", label: "신뢰" }}
      title={
        <>
          민감한 건
          <br className="sm:hidden" /> 단말이 먼저 가린다
        </>
      }
      lead="카드번호·주소 같은 식별자는 기기에서 먼저 감지하고 가린 뒤 올린다. 원본은 단말을 떠나지 않고, 모찌가 보는 건 뜻만 남은 안전한 형태다."
    >
      <div ref={ref} className="grid gap-6 lg:grid-cols-[1.1fr_1fr] lg:items-stretch">
        {/* ── 재현 카드 — 감지·마스킹·의미보존을 한 장면에 ── */}
        <GlassCard className="relative overflow-hidden p-6 sm:p-8">
          {/* "앱에서 일어나는 일"임을 정직하게 라벨. */}
          <div className="mb-5 flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full border border-black/5 bg-white/60 px-2.5 py-1 text-xs font-medium text-ink-500 backdrop-blur-md">
              <span className="h-1.5 w-1.5 rounded-full bg-mint-400" />
              앱에서 단말이 처리
            </span>
          </div>

          {/*
            [영상 슬롯] 실제 iOS 녹화가 준비되면 아래 정적 재현을 교체:
            <video src="/guard/sensitive-capture.mp4" muted autoPlay loop playsInline
                   className="w-full rounded-md" />
            지금은 영상이 없으므로 정적 다이어그램 + framer-motion 으로 재현한다.
          */}

          {/* 모의 캡처: 결제 알림 카드 */}
          <div className="relative rounded-md border border-black/5 bg-white/80 p-5 shadow-card">
            <div className="mb-4 flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-[10px] bg-ink-900/[0.04]">
                <span className="text-sm font-black text-ink-900">₩</span>
              </div>
              <div className="min-w-0">
                <p className="text-sm font-bold text-ink-900">결제 완료</p>
                <p className="truncate text-xs text-ink-300">스타벅스 · 48,000원</p>
              </div>
            </div>

            {/* 민감 라인: 카드번호 위에 마스크가 덮인다 */}
            <div className="relative">
              <div className="flex items-baseline gap-2 text-sm">
                <span className="font-medium text-ink-500">{ORIGINAL_LABEL}</span>
                <span className="font-mono tracking-tight text-ink-900">
                  {ORIGINAL_NUMBER}
                </span>
              </div>

              {/* 스캔 라인 — 감지 단계의 신호 */}
              {!reduce && inView && !masked ? (
                <motion.span
                  aria-hidden
                  className="pointer-events-none absolute inset-y-0 w-px bg-sky-400"
                  initial={{ left: "0%", opacity: 0 }}
                  animate={{ left: "100%", opacity: [0, 1, 1, 0] }}
                  transition={{ duration: 0.7, ease: "easeInOut" }}
                />
              ) : null}

              {/* 마스크 — clip-path + blur 로 덮인다. 끝자리 4개는 남겨 의미를 보존. */}
              <motion.div
                aria-hidden
                className="pointer-events-none absolute inset-0 flex items-center"
                initial={false}
                animate={{ opacity: masked ? 1 : 0 }}
                transition={{ duration: reduce ? 0 : 0.45, ease: "easeOut" }}
                style={{
                  // 라벨("신한카드 ") 너비만큼 비우고 그 뒤(번호 영역)만 덮는다.
                  clipPath: masked ? "inset(0 18% 0 32%)" : "inset(0 50% 0 50%)",
                }}
              >
                <span className="ml-[32%] h-5 flex-1 rounded-[6px] bg-ink-900/85 backdrop-blur-sm" />
              </motion.div>
            </div>

            {/* 의미 보존 칩 — 마스킹 직후 떠오른다 */}
            <motion.div
              className="mt-4 flex items-center gap-2"
              initial={false}
              animate={{
                opacity: preserved ? 1 : 0,
                y: preserved ? 0 : reduce ? 0 : 8,
              }}
              transition={{ duration: reduce ? 0 : 0.45, ease: "easeOut" }}
            >
              <ShieldCheck className="h-4 w-4 shrink-0 text-mint-400" strokeWidth={2.4} />
              <code className="rounded-[8px] bg-mint-100 px-2.5 py-1 text-xs font-semibold text-ink-900">
                {PRESERVED}
              </code>
            </motion.div>
          </div>

          <p className="mt-5 text-xs leading-relaxed text-ink-300">
            원본 번호는 단말에만 남는다. 서버로는 뜻만 남은 위 형태로 전송된다.
          </p>
        </GlassCard>

        {/* ── 3단계 미니 플로우 ── */}
        <div className="flex flex-col gap-3">
          {STEPS.map((step, i) => (
            <motion.div
              key={step.title}
              custom={i}
              variants={stepVariants}
              initial="hidden"
              animate={inView ? "show" : "hidden"}
            >
              <GlassCard className="flex items-start gap-4 p-5">
                <span
                  className={cn(
                    "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-[12px] ring-1",
                    step.tint.wrap
                  )}
                >
                  <step.Icon className={cn("h-5 w-5", step.tint.icon)} strokeWidth={2.4} />
                </span>
                <div className="min-w-0 pt-0.5">
                  <p className="text-sm font-bold text-ink-900">{step.title}</p>
                  <p className="mt-1 text-sm leading-relaxed text-ink-500">{step.body}</p>
                </div>
              </GlassCard>
            </motion.div>
          ))}
        </div>
      </div>
    </Section>
  );
}
