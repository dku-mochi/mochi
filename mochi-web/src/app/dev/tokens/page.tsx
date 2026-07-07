import Image from "next/image";

// 임시 검수 페이지 — 디자인 토큰이 HomeDesign.swift 정본과 일치하는지 육안 확인용
const SWATCHES: Array<[string, string]> = [
  ["purple-500 (브랜드)", "bg-purple-500"],
  ["purple-400", "bg-purple-400"],
  ["purple-600", "bg-purple-600"],
  ["glow", "bg-glow"],
  ["purple-100", "bg-purple-100"],
  ["ink-900", "bg-ink-900"],
  ["ink-500", "bg-ink-500"],
  ["ink-300", "bg-ink-300"],
  ["ink-100", "bg-ink-100"],
  ["bg", "bg-bg"],
  ["sky-400 (일정)", "bg-sky-400"],
  ["sky-100", "bg-sky-100"],
  ["butter-400 (할일)", "bg-butter-400"],
  ["butter-100", "bg-butter-100"],
  ["mint-400 (지식)", "bg-mint-400"],
  ["mint-100", "bg-mint-100"],
  ["blush-400 (기록)", "bg-blush-400"],
  ["blush-100", "bg-blush-100"],
  ["peach-400", "bg-peach-400"],
  ["lavender-100", "bg-lavender-100"],
  ["lavender-500", "bg-lavender-500"],
  ["lavender-900", "bg-lavender-900"],
];

const INTENT_CHIPS: Array<{ label: string; chip: string; dot: string }> = [
  { label: "일정", chip: "bg-sky-100 text-ink-900", dot: "bg-sky-400" },
  { label: "할일", chip: "bg-butter-100 text-ink-900", dot: "bg-butter-400" },
  { label: "지식", chip: "bg-mint-100 text-ink-900", dot: "bg-mint-400" },
  { label: "기록", chip: "bg-blush-100 text-ink-900", dot: "bg-blush-400" },
];

export default function TokensPage() {
  return (
    <main className="mx-auto max-w-5xl space-y-12 px-8 py-16">
      <header>
        <h1 className="font-display text-3xl tracking-head">모찌 토큰 검수</h1>
        <p className="mt-2 text-ink-500 tracking-snug">
          정본: HomeDesign.swift — 색·타이포·반경·그림자 1:1 확인
        </p>
      </header>

      <section>
        <h2 className="mb-4 text-[17px] font-extrabold tracking-snug">색상</h2>
        <div className="grid grid-cols-4 gap-3 md:grid-cols-6">
          {SWATCHES.map(([name, cls]) => (
            <div key={name} className="space-y-1.5">
              <div
                className={`h-16 rounded-md border border-ink-100 ${cls}`}
              />
              <p className="text-[11px] text-ink-500">{name}</p>
            </div>
          ))}
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-[17px] font-extrabold tracking-snug">
          타이포그래피
        </h2>
        <div className="space-y-3 rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
          <p className="font-display text-4xl tracking-head">
            뭐든지 찍어보세요 — 디스플레이
          </p>
          <p className="text-xl font-extrabold tracking-snug">
            헤드라인 20 heavy — 이번 달 모찌 리포트
          </p>
          <p className="text-[17px] font-extrabold tracking-snug">
            섹션 헤더 17 heavy — 최근에 보낸 것들
          </p>
          <p className="text-[14.5px] font-medium">
            본문 14.5 medium — 스크린샷·링크·메모를 보내기만 하면 모찌가
            정리합니다.
          </p>
          <p className="text-xs text-ink-500">캡션 12 — 3일 전 · 사파리</p>
          <p className="tnum text-2xl font-extrabold">
            1,024 — 숫자는 tabular
          </p>
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-[17px] font-extrabold tracking-snug">
          칩 · 카드 · 그림자
        </h2>
        <div className="flex flex-wrap items-center gap-3">
          {INTENT_CHIPS.map(({ label, chip, dot }) => (
            <span
              key={label}
              className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-[13px] font-semibold ${chip}`}
            >
              <span className={`size-2 rounded-full ${dot}`} />
              {label}
            </span>
          ))}
          <span className="inline-flex items-center rounded-full border border-ink-100 bg-surface px-3 py-1.5 text-[13px] font-semibold text-ink-500">
            비활성 칩
          </span>
        </div>
        <div className="mt-6 grid grid-cols-3 gap-4">
          <div className="rounded-md bg-surface p-5 shadow-card">
            <p className="text-sm font-semibold">shadow-card</p>
            <p className="mt-1 text-xs text-ink-500">radius-md 16</p>
          </div>
          <div className="rounded-lg bg-surface p-5 shadow-card-lift">
            <p className="text-sm font-semibold">shadow-card-lift</p>
            <p className="mt-1 text-xs text-ink-500">radius-lg 20</p>
          </div>
          <div className="rounded-lg bg-purple-500 p-5 text-white shadow-fab">
            <p className="text-sm font-semibold">shadow-fab</p>
            <p className="mt-1 text-xs text-purple-100">CTA·FAB</p>
          </div>
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-[17px] font-extrabold tracking-snug">
          브랜드 에셋
        </h2>
        <div className="flex flex-wrap items-end gap-6 rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
          {["mochi2", "mochi-peek", "mochi-chat", "mochi-question", "mochi-cheer"].map(
            (name) => (
              <div key={name} className="text-center">
                <Image
                  src={`/brand/${name}.png`}
                  alt={name}
                  width={72}
                  height={72}
                  className="mx-auto h-18 w-auto"
                />
                <p className="mt-1 text-[11px] text-ink-500">{name}</p>
              </div>
            ),
          )}
          {["cat-calendar", "cat-checklist", "cat-book", "cat-document"].map(
            (name) => (
              <div key={name} className="text-center">
                <Image
                  src={`/intents/${name}.png`}
                  alt={name}
                  width={48}
                  height={48}
                  className="mx-auto h-12 w-auto"
                />
                <p className="mt-1 text-[11px] text-ink-500">{name}</p>
              </div>
            ),
          )}
        </div>
      </section>
    </main>
  );
}
