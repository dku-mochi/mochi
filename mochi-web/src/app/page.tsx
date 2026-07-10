import Image from "next/image";
import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { LandingHero } from "@/components/landing/LandingHero";
import { RiseIn } from "@/components/primitives/RiseIn";

/*
 * S0 랜딩 — 미션 카피(히어로) + 여정 미리 보기 3단 + 마지막 CTA.
 * 아래 섹션은 RSC — 첫 페인트에 텍스트가 전부 실린다.
 */

const STEPS = [
  {
    icon: "/intents/cat-document.png",
    title: "남긴다",
    body: "스크린샷·링크·메모를 보내면 끝이에요. 폴더도, 태그도, 정리 규칙도 없어요.",
    scene: "기록 화면에서 직접 남겨보고 AI 분석을 지켜봐요",
  },
  {
    icon: "/intents/cat-checklist.png",
    title: "정돈된다",
    body: "남긴 것이 할 일·캘린더·지식으로 알아서 꽂혀요. 마감과 일정은 놓치지 않게.",
    scene: "홈 화면에서 일주일치 기록이 정돈된 모습을 봐요",
  },
  {
    icon: "/intents/cat-book.png",
    title: "떠오른다",
    body: "잊혀가던 기록이 찾기 전에 먼저, “왜 지금인지” 이유와 함께 떠올라요.",
    scene: "리마인드 화면, 이 데모의 하이라이트",
  },
];

export default function LandingPage() {
  return (
    <main>
      <LandingHero />

      <section className="mx-auto max-w-5xl px-6 py-24" aria-label="체험 미리 보기">
        <RiseIn index={0} inView>
          <p className="text-center text-[13px] font-bold tracking-wide text-purple-500">
            5분 체험에서 보게 될 것
          </p>
          <h2 className="mt-3 text-center font-display text-[clamp(22px,3.4vw,32px)] tracking-head [text-wrap:balance]">
            모찌가 일하는 순서
          </h2>
        </RiseIn>

        <div className="mt-12 grid gap-5 md:grid-cols-3">
          {STEPS.map((s, i) => (
            <RiseIn key={s.title} index={i + 1} inView>
              <article className="h-full rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
                <div className="flex size-14 items-center justify-center rounded-2xl bg-lavender-200/50">
                  <Image src={s.icon} alt="" width={40} height={40} />
                </div>
                <h3 className="mt-4 flex items-baseline gap-2 font-display text-[20px] tracking-head">
                  <span className="text-[13px] font-bold text-ink-300 tnum">0{i + 1}</span>
                  {s.title}
                </h3>
                <p className="mt-2 text-[14px] leading-relaxed text-ink-700">{s.body}</p>
                <p className="mt-3 text-[12.5px] font-semibold text-purple-500">{s.scene}</p>
              </article>
            </RiseIn>
          ))}
        </div>

        <RiseIn index={4} inView>
          <div className="mt-16 flex flex-col items-center gap-3">
            <Link
              href="/p"
              className="group inline-flex h-12 items-center gap-2 rounded-full bg-ink-900 px-7 text-[14.5px] font-bold text-white shadow-card transition-transform hover:scale-[1.03] active:scale-[0.98]"
            >
              체험할 사람 고르러 가기
              <ArrowRight className="size-4 transition-transform group-hover:translate-x-0.5" aria-hidden />
            </Link>
          </div>
        </RiseIn>
      </section>

      <footer className="border-t border-ink-100 bg-surface/60">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-6 py-6 text-[12.5px] text-ink-500">
          <span className="flex items-center gap-2">
            <Image src="/brand/mochi2.png" alt="" width={20} height={20} />
            <span className="font-semibold text-ink-700">모찌 · 팀 세얼간이</span>
          </span>
          <span>2026 SW중심대학 디지털 경진대회 · 심사위원용 체험 데모</span>
        </div>
      </footer>
    </main>
  );
}
