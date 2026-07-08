"use client";

import Link from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";
import { usePersona } from "./PersonaProvider";
import { cn } from "@/lib/cn";

/*
 * 페르소나 씬 상단 네비 — 자유 탐색 축. guided 진행은 JourneyRail(하단)이 담당.
 */
const TABS = [
  { seg: "", label: "홈" },
  { seg: "capture", label: "기록" },
  { seg: "search", label: "검색" },
  { seg: "chat", label: "질문" },
  { seg: "recall", label: "떠오름" },
] as const;

export function SceneNav() {
  const { persona } = usePersona();
  const pathname = usePathname();
  const base = `/p/${persona.slug}`;

  return (
    <header className="sticky top-0 z-40 border-b border-ink-100/70 bg-surface/75 backdrop-blur-xl">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-3 gap-y-0 px-5 py-2 md:h-14 md:flex-nowrap md:py-0">
        <Link
          href="/p"
          className="flex flex-none items-center gap-2 whitespace-nowrap"
          aria-label="페르소나 선택으로"
        >
          <Image src="/brand/mochi2.png" alt="" width={28} height={28} priority />
          <span className="font-display text-[17px] tracking-head">모찌</span>
        </Link>
        <span
          className="ml-1 flex-none whitespace-nowrap rounded-full bg-purple-50 px-2.5 py-1 text-[12px] font-semibold text-purple-600"
          aria-label={`현재 페르소나 ${persona.name}`}
        >
          {persona.name}
        </span>
        <nav
          className="-mx-1 flex w-full items-center gap-1 overflow-x-auto whitespace-nowrap px-1 py-1.5 md:ml-auto md:w-auto md:overflow-visible md:py-0"
          aria-label="씬 이동"
        >
          {TABS.map(({ seg, label }) => {
            const href = seg ? `${base}/${seg}` : base;
            const active =
              seg === ""
                ? pathname === base
                : pathname.startsWith(`${base}/${seg}`);
            return (
              <Link
                key={seg}
                href={href}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "flex-none rounded-full px-3.5 py-1.5 text-[13.5px] font-semibold transition-colors",
                  active
                    ? "bg-ink-900 text-white"
                    : "text-ink-500 hover:bg-ink-100/60 hover:text-ink-900",
                )}
              >
                {label}
              </Link>
            );
          })}
        </nav>
      </div>
    </header>
  );
}
