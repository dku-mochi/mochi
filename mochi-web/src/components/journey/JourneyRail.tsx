"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowRight, X } from "lucide-react";
import { usePersona } from "./PersonaProvider";
import { cn } from "@/lib/cn";

/*
 * guided 여정 레일 — 하단 상주. 진행 도트 · 다음 버튼 · → 키 · 그만 보기.
 * 진입: 페르소나 선택 CTA 의 `?guided=1` → sessionStorage 로 씬 전환에도 유지.
 * 순서(승인 플랜): 기록 → 홈 → 검색 → 질문 → 떠오름 → 피날레.
 */

const STORAGE_KEY = "mochi-guided";

const STEPS = [
  { seg: "capture", label: "기록" },
  { seg: "", label: "홈" },
  { seg: "search", label: "검색" },
  { seg: "chat", label: "질문" },
  { seg: "recall", label: "떠오름" },
] as const;

export function JourneyRail() {
  const { persona } = usePersona();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const router = useRouter();
  const reduce = useReducedMotion();
  const [active, setActive] = useState(false);

  // ?guided=1 진입 or 저장된 진행 → 레일 활성 (mount 후 — SSR 에 sessionStorage 없음)
  useEffect(() => {
    if (searchParams.get("guided") === "1") {
      sessionStorage.setItem(STORAGE_KEY, "1");
      // eslint-disable-next-line react-hooks/set-state-in-effect -- 스토리지 판독 후 1회 활성화
      setActive(true);
      return;
    }
     
    setActive(sessionStorage.getItem(STORAGE_KEY) === "1");
  }, [searchParams]);

  const base = `/p/${persona.slug}`;
  const current = STEPS.findIndex(({ seg }) =>
    seg === "" ? pathname === base : pathname.startsWith(`${base}/${seg}`),
  );
  const isLast = current === STEPS.length - 1;
  const nextHref = isLast
    ? "/finale"
    : current >= 0
      ? STEPS[current + 1].seg
        ? `${base}/${STEPS[current + 1].seg}`
        : base
      : `${base}/capture`;
  const nextLabel = isLast ? "피날레" : current >= 0 ? STEPS[current + 1].label : "기록";

  // → 키로 다음 씬 (입력 중이면 무시)
  useEffect(() => {
    if (!active) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "ArrowRight" || e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      // 코버플로우 등 씬 내부 ←→ 소비 영역이면 건드리지 않는다
      if (t && t.closest("[data-owns-arrows]")) return;
      router.push(nextHref);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [active, nextHref, router]);

  const exit = () => {
    sessionStorage.removeItem(STORAGE_KEY);
    setActive(false);
  };

  return (
    <AnimatePresence>
      {active && (
        <motion.nav
          /* 우하단 도킹 — 중앙 하단은 채팅 입력창·회수 캡션과 겹친다 */
          className="fixed bottom-5 right-5 z-50"
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 18 }}
          animate={reduce ? { opacity: 1 } : { opacity: 1, y: 0 }}
          exit={{ opacity: 0, transition: { duration: 0.18 } }}
          transition={{ type: "spring", duration: 0.5, bounce: 0.2 }}
          aria-label="여정 진행"
        >
          <div className="flex items-center gap-3 rounded-full border border-ink-100/80 bg-surface/85 py-1.5 pl-4 pr-1.5 shadow-card-lift backdrop-blur-xl">
            <ol className="flex items-center gap-1.5" aria-label="여정 단계">
              {STEPS.map(({ seg, label }, i) => (
                <li key={label}>
                  <Link
                    href={seg ? `${base}/${seg}` : base}
                    aria-current={i === current ? "step" : undefined}
                    aria-label={`${i + 1}. ${label}`}
                    title={label}
                    className={cn(
                      "relative block rounded-full transition-all duration-300 after:absolute after:-inset-2 after:content-['']",
                      i === current
                        ? "h-2 w-5 bg-purple-500"
                        : i < current
                          ? "size-2 bg-purple-200 hover:bg-purple-400"
                          : "size-2 bg-ink-100 hover:bg-ink-300",
                    )}
                  />
                </li>
              ))}
            </ol>

            <Link
              href={nextHref}
              className="inline-flex h-9 items-center gap-1.5 rounded-full bg-ink-900 pl-4 pr-3 text-[13px] font-bold text-white transition-transform hover:scale-[1.03] active:scale-[0.97]"
            >
              다음 · {nextLabel}
              <ArrowRight className="size-3.5" aria-hidden />
            </Link>

            <button
              onClick={exit}
              aria-label="안내 여정 그만 보기 — 자유롭게 탐색"
              title="자유롭게 볼게요"
              className="flex size-8 items-center justify-center rounded-full text-ink-300 transition-colors hover:bg-ink-100/70 hover:text-ink-700"
            >
              <X className="size-4" aria-hidden />
            </button>
          </div>
          <p className="mt-1.5 pr-2 text-right text-[10.5px] font-medium text-ink-300">
            → 키로도 넘어가요
          </p>
        </motion.nav>
      )}
    </AnimatePresence>
  );
}
