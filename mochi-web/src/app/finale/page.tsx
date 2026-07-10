import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowRight, MoveRight, RotateCcw } from "lucide-react";
import { PERSONAS } from "@seed/index";
import { RiseIn } from "@/components/primitives/RiseIn";
import { LiveEvidence } from "@/components/finale/LiveEvidence";

export const metadata: Metadata = { title: "마무리" };

/*
 * S7 피날레 — "데모가 아니라 작동하는 제품".
 * 여정 요약 3칸 + 아키텍처 다이어그램 + GitHub QR + 페르소나 재선택.
 * MochiWalk 스프라이트는 globals.css `.mochi-walk` (CSS steps, reduce-motion 정지).
 */

const SUMMARY = [
  {
    icon: "/intents/cat-document.png",
    title: "남겼다",
    body: "기록 화면에서 직접 남긴 캡처가 실제 AI 분석을 거쳐 저장됐어요. 폴더도 태그도 고르지 않았어요.",
  },
  {
    icon: "/intents/cat-checklist.png",
    title: "찾았다",
    body: "검색과 질문의 답은 언제나 실제 기록 근거와 함께 왔어요. 기록을 바꾸는 일은 제안 카드에서 직접 확정했어요.",
  },
  {
    icon: "/intents/cat-book.png",
    title: "떠올랐다",
    body: "잊혀가던 기록이 “왜 지금인지” 이유와 함께 먼저 떠올랐어요. 먼저 떠올린 쪽은 사용자가 아니라 모찌예요.",
  },
];

/** 아키텍처 한 단 — 라벨 + 설명 박스 */
function ArchNode({
  name,
  detail,
  accent,
}: {
  name: string;
  detail: string;
  accent?: boolean;
}) {
  return (
    <div
      className={
        accent
          ? "rounded-2xl border border-purple-200 bg-purple-50 px-4 py-3 text-center shadow-card"
          : "rounded-2xl border border-ink-100 bg-surface px-4 py-3 text-center shadow-card"
      }
    >
      <p className="text-[13.5px] font-bold text-ink-900">{name}</p>
      <p className="mt-0.5 text-[11.5px] font-medium text-ink-500">{detail}</p>
    </div>
  );
}

export default function FinalePage() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <div
        className="absolute inset-x-0 top-0 h-[460px] bg-gradient-to-b from-lavender-200/70 to-transparent"
        aria-hidden
      />

      <div className="relative mx-auto max-w-5xl px-6 pb-24 pt-16">
        {/* 히어로 — 걷는 모찌 + 결론 */}
        <RiseIn index={0}>
          <div className="flex flex-col items-center text-center">
            <div className="mochi-walk" role="img" aria-label="걸어가는 모찌" />
            <h1 className="mt-6 font-display text-[clamp(26px,4.5vw,42px)] tracking-head [text-wrap:balance]">
              기록은 남았고,
              <br />
              필요할 때{" "}
              <span className="bg-gradient-to-r from-purple-500 to-purple-600 bg-clip-text text-transparent">
                떠올랐어요
              </span>
            </h1>
            <p className="mt-4 max-w-lg text-[14.5px] leading-relaxed text-ink-700">
              방금 보신 건 목업이 아니라 작동하는 제품이에요.
              채팅·검색·라이브 분석은 실제 백엔드가 응답했어요.
            </p>
          </div>
        </RiseIn>

        {/* 여정 요약 3칸 */}
        <div className="mt-14 grid gap-5 md:grid-cols-3">
          {SUMMARY.map((s, i) => (
            <RiseIn key={s.title} index={i + 1} inView>
              <article className="h-full rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
                <div className="flex size-12 items-center justify-center rounded-xl bg-lavender-200/50">
                  <Image src={s.icon} alt="" width={32} height={32} />
                </div>
                <h2 className="mt-3.5 font-display text-[19px] tracking-head">{s.title}</h2>
                <p className="mt-2 text-[13.5px] leading-relaxed text-ink-700">{s.body}</p>
              </article>
            </RiseIn>
          ))}
        </div>

        {/* 아키텍처 — 데모 웹이 지나온 길 */}
        <RiseIn index={1} inView>
          <section
            className="mt-16 rounded-lg border border-ink-100 bg-surface p-7 shadow-card"
            aria-label="시스템 아키텍처"
          >
            <h2 className="font-display text-[20px] tracking-head">
              방금 응답을 처리한 시스템
            </h2>
            <div className="mt-6 grid items-center gap-3 md:grid-cols-[1fr_auto_1fr_auto_1fr]">
              <div className="space-y-3">
                <ArchNode name="iOS 앱 (정본)" detail="SwiftUI · TCA, 캡처와 회수 알림" />
                <ArchNode name="데모 웹" detail="Next.js BFF, 지금 이 화면" />
              </div>
              <MoveRight className="mx-auto size-5 rotate-90 text-ink-300 md:rotate-0" aria-hidden />
              <ArchNode
                name="FastAPI 백엔드"
                detail="Modular Monolith · JWT · SSE 스트림"
                accent
              />
              <MoveRight className="mx-auto size-5 rotate-90 text-ink-300 md:rotate-0" aria-hidden />
              <div className="space-y-3">
                <ArchNode name="Gemini" detail="분석 · 채팅 에이전트" />
                <ArchNode name="pgvector · GCS" detail="하이브리드 검색 · 캡처 저장" />
              </div>
            </div>
            <p className="mt-5 rounded-xl bg-bg px-4 py-3 text-[12.5px] leading-relaxed text-ink-500">
              <span className="font-bold text-ink-700">iOS 앱·데모 웹·백엔드가 같은 OpenAPI 명세 하나를 써요.</span>{" "}
              방금 보신 채팅·검색·분석 응답도 실제 제품과 같은 포맷이에요.
            </p>
            <LiveEvidence />
          </section>
        </RiseIn>

        {/* GitHub QR + 재선택 */}
        <div className="mt-8 grid gap-5 md:grid-cols-2">
          <RiseIn index={2} inView className="h-full">
            <section className="flex h-full items-center gap-5 rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
              <Image
                src="/qr-github.svg"
                alt="GitHub 저장소 QR 코드"
                width={104}
                height={104}
                className="rounded-lg border border-ink-100 bg-white p-1.5"
              />
              <div>
                <h2 className="font-display text-[18px] tracking-head">코드로 확인하기</h2>
                <p className="mt-1.5 text-[13px] leading-relaxed text-ink-500">
                  iOS · 백엔드 · 이 데모 웹까지 한 저장소에 있어요.
                  iOS 앱은 시연 기기에서 바로 볼 수 있어요.
                </p>
                <p className="mt-2 text-[12px] font-semibold text-purple-500">
                  github.com/dku-mochi/mochi
                </p>
              </div>
            </section>
          </RiseIn>

          <RiseIn index={3} inView className="h-full">
            <section className="flex h-full flex-col rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
              <h2 className="font-display text-[18px] tracking-head">
                다른 사람의 일주일도 있어요
              </h2>
              <div className="mt-3.5 flex flex-wrap gap-2">
                {PERSONAS.map((p) => (
                  <Link
                    key={p.slug}
                    href={`/p/${p.slug}/capture?guided=1`}
                    className="inline-flex h-10 items-center gap-1.5 rounded-full border border-ink-100 bg-bg/60 px-4 text-[13px] font-bold text-ink-700 transition-colors hover:border-purple-200 hover:bg-purple-50 hover:text-purple-600"
                  >
                    {p.name}
                    <span className="font-medium text-ink-300">{p.job}</span>
                    <ArrowRight className="size-3.5" aria-hidden />
                  </Link>
                ))}
              </div>
              <Link
                href="/"
                className="mt-auto inline-flex items-center gap-1.5 pt-4 text-[12.5px] font-semibold text-ink-500 transition-colors hover:text-ink-900"
              >
                <RotateCcw className="size-3.5" aria-hidden />
                처음 화면으로
              </Link>
            </section>
          </RiseIn>
        </div>

        <p className="mt-12 text-center text-[12px] text-ink-300">
          2026 SW중심대학 디지털 경진대회 · 팀 세얼간이
        </p>
      </div>
    </main>
  );
}
