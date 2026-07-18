"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowRight, SkipForward, X } from "lucide-react";
import { usePersona } from "./PersonaProvider";
import {
  ensureJourney,
  skipJourneyStep,
  startJourney,
  useJourneySession,
  type JourneyStep,
} from "@/lib/journeySession";
import { cn } from "@/lib/cn";

const STORAGE_KEY = "mochi-guided";
const STEP_KEY = "mochi-guided-step";

const STEPS: Array<{ key: JourneyStep; seg: string; label: string; prompt: string }> = [
  { key: "capture", seg: "capture", label: "기록", prompt: "기록 1건을 보내면 다음으로 이어져요" },
  { key: "home", seg: "", label: "홈", prompt: "방금 기록이 홈에 쌓인 모습을 확인해보세요" },
  { key: "search", seg: "search", label: "검색", prompt: "추천이나 자유 입력으로 한 번 찾아보세요" },
  { key: "chat", seg: "chat", label: "질문", prompt: "추천이나 자유 입력으로 한 번 물어보세요" },
  { key: "recall", seg: "recall", label: "리마인드", prompt: "모찌가 먼저 떠올린 기록을 확인해보세요" },
];

export function JourneyRail() {
  const { persona } = usePersona();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const router = useRouter();
  const reduce = useReducedMotion();
  const journey = useJourneySession();
  const initialized = useRef(false);
  const [active, setActive] = useState(false);

  useEffect(() => {
    const guided = searchParams.get("guided") === "1";
    const fresh = searchParams.get("new") === "1";

    if (fresh && !initialized.current) {
      initialized.current = true;
      startJourney(persona.slug);
      sessionStorage.setItem(STORAGE_KEY, "1");
      setActive(true);
      const next = new URLSearchParams(searchParams.toString());
      next.delete("new");
      router.replace(`${pathname}?${next.toString()}`, { scroll: false });
      return;
    }

    if (guided || sessionStorage.getItem(STORAGE_KEY) === "1") {
      ensureJourney(persona.slug);
      if (guided) sessionStorage.setItem(STORAGE_KEY, "1");
      // eslint-disable-next-line react-hooks/set-state-in-effect -- sessionStorage 기반 안내 상태 복원
      setActive(true);
      return;
    }
    setActive(false);
  }, [pathname, persona.slug, router, searchParams]);

  const base = `/p/${persona.slug}`;
  const current = STEPS.findIndex(({ seg }) =>
    seg === "" ? pathname === base : pathname.startsWith(`${base}/${seg}`),
  );
  const stepKey = `${STEP_KEY}-${persona.slug}`;
  const [lastStep, setLastStep] = useState(-1);

  useEffect(() => {
    if (current >= 0) {
      sessionStorage.setItem(stepKey, String(current));
      // eslint-disable-next-line react-hooks/set-state-in-effect -- 현재 라우트를 상세 화면 복귀용으로 기억
      setLastStep(current);
      return;
    }
    const stored = Number(sessionStorage.getItem(stepKey) ?? "-1");
    setLastStep(Number.isInteger(stored) && stored >= 0 ? stored : -1);
  }, [current, stepKey]);

  const effective = current >= 0 ? current : lastStep;
  const activeStep = effective >= 0 ? STEPS[effective] : STEPS[0];
  const stepStatus = journey?.personaSlug === persona.slug
    ? journey.steps[activeStep.key].status
    : "pending";
  const canAdvance = stepStatus !== "pending";
  const isLast = effective === STEPS.length - 1;
  const nextHref = isLast
    ? "/finale"
    : effective >= 0
      ? STEPS[effective + 1].seg
        ? `${base}/${STEPS[effective + 1].seg}`
        : base
      : `${base}/capture`;
  const nextLabel = isLast ? "마무리" : effective >= 0 ? STEPS[effective + 1].label : "기록";
  const recallWaiting = current === STEPS.length - 1 && !canAdvance;
  const arrowsOwnedByScene = pathname.startsWith(`${base}/recall`);

  useEffect(() => {
    if (!active || arrowsOwnedByScene || !canAdvance) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "ArrowRight" || event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return;
      if (target?.closest("[data-owns-arrows], select, [role='slider'], [role='radiogroup'], [role='tablist'], [role='listbox'], [role='menu']")) return;
      event.preventDefault();
      router.push(nextHref);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [active, arrowsOwnedByScene, canAdvance, nextHref, router]);

  const exit = () => {
    sessionStorage.removeItem(STORAGE_KEY);
    setActive(false);
  };

  const skip = () => {
    skipJourneyStep(persona.slug, activeStep.key);
    router.push(nextHref);
  };

  // 리마인드 인터스티셜 위에서는 exit 애니메이션조차 클릭 표면을 남기지 않는다.
  if (recallWaiting) return null;

  return (
    <AnimatePresence>
      {active && (
        <motion.nav
          className="fixed inset-x-3 bottom-3 z-50 sm:inset-x-auto sm:bottom-5 sm:right-5"
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 18 }}
          animate={reduce ? { opacity: 1 } : { opacity: 1, y: 0 }}
          exit={{ opacity: 0, transition: { duration: 0.18 } }}
          transition={{ type: "spring", duration: 0.5, bounce: 0.2 }}
          aria-label="체험 진행"
        >
          <div className="flex items-center gap-2 rounded-2xl border border-ink-100/80 bg-surface/90 py-2 pl-3 pr-2 shadow-card-lift backdrop-blur-xl sm:rounded-full sm:pl-4">
            <ol className="flex flex-none items-center gap-1.5" aria-label="체험 단계">
              {STEPS.map(({ seg, label, key }, index) => {
                const status = journey?.personaSlug === persona.slug
                  ? journey.steps[key].status
                  : "pending";
                const dotClass = cn(
                  "relative block rounded-full transition-all duration-300 after:absolute after:-inset-2 after:content-['']",
                  index === effective
                    ? "h-2 w-5 bg-purple-500"
                    : status !== "pending"
                      ? "size-2 bg-purple-200"
                      : "size-2 bg-ink-100",
                );
                const href = seg ? `${base}/${seg}` : base;
                return (
                  <li key={key}>
                    {status !== "pending" || index <= effective ? (
                      <Link
                        href={href}
                        aria-current={index === effective ? "step" : undefined}
                        aria-label={`${index + 1}. ${label}${status === "skipped" ? " 건너뜀" : ""}`}
                        title={label}
                        className={cn(dotClass, "hover:bg-purple-400")}
                      />
                    ) : (
                      <span aria-label={`${index + 1}. ${label}, 아직 전`} className={dotClass} />
                    )}
                  </li>
                );
              })}
            </ol>

            {canAdvance ? (
              <Link
                href={nextHref}
                className="ml-auto inline-flex h-9 flex-none items-center gap-1.5 rounded-full bg-ink-900 pl-4 pr-3 text-[13px] font-bold text-white transition-transform hover:scale-[1.03] active:scale-[0.97]"
              >
                다음 · {nextLabel}
                <ArrowRight className="size-3.5" aria-hidden />
              </Link>
            ) : (
              <p className="ml-auto min-w-0 flex-1 truncate text-right text-[11.5px] font-semibold text-ink-500 sm:max-w-[240px]">
                {activeStep.prompt}
              </p>
            )}

            {!canAdvance && (
              <button
                onClick={skip}
                aria-label={`${activeStep.label} 건너뛰고 ${nextLabel}으로`}
                title="이 단계 건너뛰기"
                className="flex size-8 flex-none items-center justify-center rounded-full text-ink-400 transition-colors hover:bg-ink-100/70 hover:text-ink-700"
              >
                <SkipForward className="size-4" aria-hidden />
              </button>
            )}

            <button
              onClick={exit}
              aria-label="안내 그만 보기"
              title="자유롭게 볼게요"
              className="flex size-8 flex-none items-center justify-center rounded-full text-ink-300 transition-colors hover:bg-ink-100/70 hover:text-ink-700"
            >
              <X className="size-4" aria-hidden />
            </button>
          </div>
          <p className="mt-1.5 hidden pr-2 text-right text-[10.5px] font-medium text-ink-300 sm:block">
            {canAdvance ? "→ 키로도 넘어가요" : "완료하거나 건너뛸 수 있어요"}
          </p>
        </motion.nav>
      )}
    </AnimatePresence>
  );
}
