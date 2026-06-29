import type { ReactNode } from "react";
import Image from "next/image";
import {
  Camera,
  PlaySquare,
  Link2,
  Check,
  CalendarDays,
  Bookmark,
  Quote,
  Clock,
  History,
  GitCompare,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { INTENT_LABEL, type IntentType, type RecallReason, type TintKey } from "@/lib/types";
import { useJudgeMode } from "@/components/JudgeMode";

export { PillButton } from "./PillButton";

/* ─────────────────────────────────────────────────────────────
   Tailwind purge 안전을 위해 색 클래스는 전부 정적 record 로 둔다.
   동적 `bg-${tint}-400` 금지 — 빌드 시 클래스가 사라진다.
   ───────────────────────────────────────────────────────────── */
const TINT_DOT: Record<TintKey, string> = {
  purple: "bg-purple-400",
  blush: "bg-blush-400",
  mint: "bg-mint-400",
  butter: "bg-butter-400",
  sky: "bg-sky-400",
  peach: "bg-peach-400",
};

/* ── Eyebrow ───────────────────────────────────────────────── */
export function Eyebrow({
  tint = "purple",
  children,
}: {
  tint?: TintKey;
  children: ReactNode;
}) {
  return (
    <span className="inline-flex items-center gap-2">
      <span className={cn("h-1.5 w-1.5 rounded-full", TINT_DOT[tint])} />
      <span className="text-xs font-semibold uppercase tracking-[0.18em] text-ink-500">
        {children}
      </span>
    </span>
  );
}

/* ── Section ───────────────────────────────────────────────── */
export function Section({
  id,
  eyebrow,
  title,
  lead,
  children,
  className,
}: {
  id?: string;
  eyebrow?: { tint?: TintKey; label: ReactNode };
  title: ReactNode;
  lead?: ReactNode;
  children?: ReactNode;
  className?: string;
}) {
  return (
    <section
      id={id}
      className={cn(
        "scroll-mt-24 px-5 py-24 sm:py-28 md:py-32",
        className
      )}
    >
      <div className="mx-auto max-w-5xl">
        <header className="max-w-3xl">
          {eyebrow ? (
            <div className="mb-4">
              <Eyebrow tint={eyebrow.tint}>{eyebrow.label}</Eyebrow>
            </div>
          ) : null}
          <h2 className="text-balance text-3xl font-black tracking-tight text-ink-900 sm:text-4xl md:text-5xl">
            {title}
          </h2>
          {lead ? (
            <p className="mt-5 text-pretty text-base leading-relaxed text-ink-500 sm:text-lg">
              {lead}
            </p>
          ) : null}
        </header>
        {children ? <div className="mt-12">{children}</div> : null}
      </div>
    </section>
  );
}

/* ── GlassCard ─────────────────────────────────────────────── */
export function GlassCard({
  className,
  children,
}: {
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={cn(
        "rounded-xl border border-black/5 bg-white/70 shadow-card backdrop-blur-xl",
        className
      )}
    >
      {children}
    </div>
  );
}

/* ── SourceChip ────────────────────────────────────────────── */
const SOURCE_ICON: Record<
  "screenshot" | "youtube" | "link",
  { Icon: typeof Camera; label: string }
> = {
  screenshot: { Icon: Camera, label: "스크린샷" },
  youtube: { Icon: PlaySquare, label: "YouTube" },
  link: { Icon: Link2, label: "링크" },
};

function classifySource(source: string): keyof typeof SOURCE_ICON {
  const s = source.toLowerCase();
  if (s.includes("youtube") || s.includes("youtu.be")) return "youtube";
  if (s.includes("스크린샷") || s.includes("screenshot") || s.includes("캡처"))
    return "screenshot";
  return "link";
}

export function SourceChip({ source }: { source: string }) {
  const kind = classifySource(source);
  const { Icon, label } = SOURCE_ICON[kind];
  const text = source.trim().length > 0 ? source : label;
  return (
    <span className="inline-flex max-w-full items-center gap-1.5 rounded-full border border-black/5 bg-white/60 px-2.5 py-1 text-xs font-medium text-ink-500 backdrop-blur-md">
      <Icon className="h-3.5 w-3.5 shrink-0 text-ink-300" strokeWidth={2} />
      <span className="truncate">{text}</span>
    </span>
  );
}

/* ── BehaviorMark ──────────────────────────────────────────────
   ★ intent 를 라벨 없이 "행동의 형태"로만 노출 (제품 미션).
   라벨 텍스트는 심사위원 오버레이에서만. 색 클래스는 정적 record.
   ───────────────────────────────────────────────────────────── */
const BEHAVIOR: Record<
  IntentType,
  { Icon: typeof Check; wrap: string; icon: string; aria: string }
> = {
  todo: {
    Icon: Check,
    wrap: "bg-butter-100 ring-1 ring-butter-400/30",
    icon: "text-butter-400",
    aria: "할 일",
  },
  schedule: {
    Icon: CalendarDays,
    wrap: "bg-sky-100 ring-1 ring-sky-400/30",
    icon: "text-sky-400",
    aria: "일정",
  },
  knowledge: {
    Icon: Bookmark,
    wrap: "bg-mint-100 ring-1 ring-mint-400/30",
    icon: "text-mint-400",
    aria: "지식",
  },
  memo: {
    Icon: Quote,
    wrap: "bg-blush-100 ring-1 ring-blush-400/30",
    icon: "text-blush-400",
    aria: "기록",
  },
};

const MARK_SIZE = {
  sm: { box: "h-6 w-6 rounded-[7px]", icon: "h-3.5 w-3.5" },
  md: { box: "h-8 w-8 rounded-[9px]", icon: "h-4 w-4" },
  lg: { box: "h-11 w-11 rounded-[12px]", icon: "h-5 w-5" },
} as const;

export function BehaviorMark({
  intent,
  size = "md",
}: {
  intent: IntentType;
  size?: keyof typeof MARK_SIZE;
}) {
  const { on: judge } = useJudgeMode();
  const b = BEHAVIOR[intent];
  const dim = MARK_SIZE[size];
  // todo 의 체크박스는 "둥근 사각 + 안의 체크"로 행동을 더 또렷이.
  const isTodo = intent === "todo";
  const mark = (
    <span
      role="img"
      aria-label={b.aria}
      className={cn(
        "inline-flex shrink-0 items-center justify-center",
        dim.box,
        b.wrap,
        isTodo && "ring-[1.5px] ring-butter-400/50"
      )}
    >
      <b.Icon className={cn(dim.icon, b.icon)} strokeWidth={2.4} />
    </span>
  );

  // ★ 심사위원 모드: 행동의 형태 옆에 INTENT_LABEL 을 드러낸다 (평소엔 숨김).
  if (judge) {
    return (
      <span className="inline-flex items-center gap-1.5">
        {mark}
        <span
          className={cn(
            "rounded-full px-1.5 py-0.5 text-[11px] font-bold tracking-tight",
            b.wrap,
            b.icon
          )}
        >
          {INTENT_LABEL[intent]}
        </span>
      </span>
    );
  }

  return mark;
}

/* ── ReasonChip ────────────────────────────────────────────────
   회수 규칙 칩 — "왜 지금 떠올랐는지" 증명.
   ───────────────────────────────────────────────────────────── */
const REASON: Record<
  RecallReason["kind"],
  { Icon: typeof Clock; chip: string; icon: string }
> = {
  deadline: {
    Icon: Clock,
    chip: "bg-peach-100 text-peach-400 border-peach-400/20",
    icon: "text-peach-400",
  },
  decay: {
    Icon: History,
    chip: "bg-purple-100 text-purple-500 border-purple-400/20",
    icon: "text-purple-500",
  },
  similarity: {
    Icon: GitCompare,
    chip: "bg-mint-100 text-mint-400 border-mint-400/20",
    icon: "text-mint-400",
  },
};

export function ReasonChip({ reason }: { reason: RecallReason }) {
  const r = REASON[reason.kind];
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-semibold",
        r.chip
      )}
    >
      <r.Icon className={cn("h-3.5 w-3.5 shrink-0", r.icon)} strokeWidth={2.4} />
      <span className="truncate">{reason.label}</span>
    </span>
  );
}

/* ── MochiSprite ───────────────────────────────────────────── */
type MochiPose = "hello" | "peek" | "question" | "chat";

// 원본 PNG 비율(가로:세로). peek 만 와이드라 정사각형이 아니다 — size 를
// 가로 기준으로 두고 세로는 비율대로 산출해 next/image 의 비율 경고를 막는다.
const MOCHI_RATIO: Record<MochiPose, number> = {
  hello: 1,
  question: 1,
  chat: 1,
  peek: 281 / 664,
};

export function MochiSprite({
  pose = "hello",
  size = 96,
  className,
}: {
  pose?: MochiPose;
  size?: number;
  className?: string;
}) {
  return (
    <Image
      src={`/mochi/mochi-${pose}.png`}
      alt=""
      width={size}
      height={Math.round(size * MOCHI_RATIO[pose])}
      aria-hidden
      draggable={false}
      className={cn("select-none object-contain", className)}
    />
  );
}
