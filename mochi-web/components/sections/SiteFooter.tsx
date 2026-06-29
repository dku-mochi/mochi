import { MochiSprite } from "@/components/ui";

/* ─────────────────────────────────────────────────────────────
   SiteFooter — 절제된 마무리.
   팀·아키텍처 한 줄·배포 링크 placeholder·모찌 캐릭터.
   ★ 큰 그라데이션·동반자 서사 금지. 색은 작은 신호로만.
   ───────────────────────────────────────────────────────────── */

const STORE_LINKS = [
  { label: "App Store", href: "#" },
  { label: "TestFlight", href: "#" },
] as const;

export function SiteFooter() {
  return (
    <footer className="border-t border-black/5 px-5 pb-16 pt-20">
      <div className="mx-auto flex max-w-5xl flex-col gap-12">
        {/* 상단: 모찌 + 미션 한 줄 / 배포 링크 */}
        <div className="flex flex-col gap-10 sm:flex-row sm:items-end sm:justify-between">
          <div className="flex items-end gap-4">
            <MochiSprite pose="peek" size={64} className="shrink-0" />
            <div>
              <p className="text-2xl font-black tracking-tight text-ink-900">
                모찌
              </p>
              <p className="mt-1.5 max-w-xs text-pretty text-sm leading-relaxed text-ink-500">
                놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다.
              </p>
            </div>
          </div>

          <nav aria-label="앱 내려받기" className="flex items-center gap-3">
            {STORE_LINKS.map(({ label, href }) => (
              <a
                key={label}
                href={href}
                aria-disabled
                className="inline-flex items-center rounded-full border border-black/5 bg-white/60 px-4 py-2 text-sm font-semibold text-ink-500 shadow-card backdrop-blur-md transition-colors hover:text-ink-900"
              >
                {label}
              </a>
            ))}
          </nav>
        </div>

        {/* 하단: 아키텍처 한 줄 / 팀·경진대회 */}
        <div className="flex flex-col gap-4 border-t border-black/5 pt-8 text-xs text-ink-300 sm:flex-row sm:items-center sm:justify-between">
          <p className="font-medium">
            iOS SwiftUI&nbsp;+&nbsp;TCA
            <span className="mx-2 text-ink-300/60">·</span>
            FastAPI
            <span className="mx-2 text-ink-300/60">·</span>
            멀티모달 AI
          </p>
          <p>
            <span className="font-semibold text-ink-500">세얼간이</span>
            <span className="mx-2 text-ink-300/60">·</span>
            2026 SW중심대학 디지털 경진대회
          </p>
        </div>
      </div>
    </footer>
  );
}
