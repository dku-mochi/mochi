import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowRight, ExternalLink, RotateCcw } from "lucide-react";
import { PERSONAS } from "@seed/index";
import { RiseIn } from "@/components/primitives/RiseIn";
import { JourneyOutcome } from "@/components/finale/JourneyOutcome";
import { TESTFLIGHT_URL } from "@/lib/productLinks";
import { isCodeRepositoryVisible } from "@/lib/releaseSchedule";

export const metadata: Metadata = { title: "마무리" };
export const dynamic = "force-dynamic";

/*
 * S7 피날레 — "데모가 아니라 작동하는 제품".
 * 여정 요약 3칸 + TestFlight + 공개일 이후 GitHub QR + 페르소나 재선택.
 * MochiWalk 스프라이트는 globals.css `.mochi-walk` (CSS steps, reduce-motion 정지).
 */

export default function FinalePage() {
  const showCodeRepository = isCodeRepositoryVisible();

  return (
    <main className="relative min-h-dvh overflow-hidden">
      <div
        className="absolute inset-x-0 top-0 h-[460px] bg-gradient-to-b from-lavender-200/70 to-transparent"
        aria-hidden
      />

      <div className="relative mx-auto max-w-5xl px-6 pb-24 pt-16">
        <JourneyOutcome />

        <RiseIn index={1} inView>
          <section
            className="mt-12 grid items-center gap-6 rounded-lg border border-purple-200 bg-purple-50 p-6 shadow-card sm:grid-cols-[132px_1fr] lg:grid-cols-[132px_1fr_auto]"
            aria-label="TestFlight에서 모찌 설치"
          >
            <Image
              src="/qr-testflight.svg"
              alt="모찌 TestFlight 설치 QR 코드"
              width={132}
              height={132}
              className="size-[132px] rounded-lg border border-purple-100 bg-white p-2"
            />
            <div>
              <p className="text-[12px] font-bold text-purple-600">iPhone 앱</p>
              <h2 className="mt-1 font-display text-[22px] tracking-head">
                이제 내 기억을 모찌에게 맡겨보세요
              </h2>
              <p className="mt-2 max-w-xl text-[13.5px] leading-relaxed text-ink-700">
                QR 코드를 스캔하거나 이 기기에서 TestFlight를 열면 실제 모찌 앱을 설치할 수 있어요.
              </p>
            </div>
            <a
              href={TESTFLIGHT_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-11 w-full items-center justify-center gap-1.5 rounded-full bg-purple-600 px-5 text-[13.5px] font-bold text-white shadow-fab transition-colors hover:bg-purple-500 sm:col-start-2 sm:w-fit lg:col-start-auto"
            >
              TestFlight에서 설치하기
              <ExternalLink className="size-4" aria-hidden />
            </a>
          </section>
        </RiseIn>

        {/* GitHub QR(공개일 이후) + 재선택 */}
        <div className={`mt-8 grid gap-5 ${showCodeRepository ? "md:grid-cols-2" : ""}`}>
          {showCodeRepository && (
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
          )}

          <RiseIn index={showCodeRepository ? 3 : 2} inView className="h-full">
            <section className="flex h-full flex-col rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
              <h2 className="font-display text-[18px] tracking-head">
                다른 사람의 일주일도 있어요
              </h2>
              <div className="mt-3.5 flex flex-wrap gap-2">
                {PERSONAS.map((p) => (
                  <Link
                    key={p.slug}
                    href={`/p/${p.slug}/capture?guided=1&new=1`}
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
