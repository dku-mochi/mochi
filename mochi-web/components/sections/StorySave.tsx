"use client";

import Image from "next/image";
import { motion, useReducedMotion, type Variants } from "framer-motion";
import { Section, GlassCard, BehaviorMark, SourceChip } from "@/components/ui";
import { SAMPLE_CARDS } from "@/seed/samples";

// 캡처 1건이 공유시트로 들어와 — 라벨 없이 "행동의 형태"로만 정리되는 순간.
// mymind/Notion 처럼 사용자가 폴더·태그를 고르는 게 아니라, 모찌가 알아서.
const card = SAMPLE_CARDS[0]; // 데이콘 경진대회 일정 (schedule + todo)

const reveal: Variants = {
  hidden: { opacity: 0, y: 24 },
  show: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { delay: 0.12 * i, duration: 0.55, ease: [0.22, 1, 0.36, 1] },
  }),
};

export function StorySave() {
  const reduce = useReducedMotion();
  const viewport = { once: true, amount: 0.5 };

  // reduce-motion: variants 의 delay/transition 을 무력화해 즉시 정적 표시.
  const animate = reduce ? "show" : undefined;
  const whileInView = reduce ? undefined : "show";

  return (
    <Section
      id="story-save"
      eyebrow={{ tint: "purple", label: "보이지 않는 정리" }}
      title={
        <>
          담는 순간,
          <br className="hidden sm:block" /> 이미 정리는 끝나 있다.
        </>
      }
      lead="공유시트로 툭 넣기만 하면 돼요. 폴더를 만들 일도, 태그를 고를 일도 없어요. 무엇으로 쓸지는 모찌가 알아서 정합니다."
    >
      <motion.div
        className="relative mx-auto max-w-md"
        initial={reduce ? false : "hidden"}
        animate={animate}
        whileInView={whileInView}
        viewport={viewport}
      >
        {/* 공유시트에서 떠오르는 캡처 카드 */}
        <motion.div custom={0} variants={reveal}>
          <GlassCard className="overflow-hidden">
            {card.imageUrl ? (
              <div className="relative aspect-[4/3] w-full overflow-hidden">
                <Image
                  src={card.imageUrl}
                  alt=""
                  fill
                  sizes="(max-width: 640px) 100vw, 28rem"
                  className="object-cover"
                  aria-hidden
                />
                <div className="absolute inset-x-0 bottom-0 h-20 bg-gradient-to-t from-black/30 to-transparent" />
                {card.source ? (
                  <div className="absolute left-3 top-3">
                    <SourceChip source={card.source} />
                  </div>
                ) : null}
              </div>
            ) : null}

            <div className="p-5">
              <h3 className="text-pretty text-lg font-black tracking-tight text-ink-900">
                {card.title}
              </h3>
              <p className="mt-1.5 text-sm leading-relaxed text-ink-500">
                {card.oneline}
              </p>

              {/* ★ intent 라벨 없이 — "행동의 형태"만 떠오른다 */}
              <motion.div
                custom={1}
                variants={reveal}
                className="mt-5 flex items-center gap-2.5 border-t border-black/5 pt-4"
              >
                {card.intents.map((intent) => (
                  <BehaviorMark key={intent} intent={intent} size="md" />
                ))}
                <span className="ml-auto text-xs font-medium text-ink-300">
                  방금 담음
                </span>
              </motion.div>
            </div>
          </GlassCard>
        </motion.div>

        {/* 담담한 한 줄 — "분류했어요" 라고 말하지 않는다 */}
        <motion.p
          custom={2}
          variants={reveal}
          className="mt-6 text-center text-sm text-ink-500"
        >
          “분류했어요” 같은 말은 하지 않아요. 필요할 때 알맞은 모습으로 떠오를 뿐.
        </motion.p>
      </motion.div>
    </Section>
  );
}
