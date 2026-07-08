"use client";

import Image from "next/image";
import Link from "next/link";
import { useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Search } from "lucide-react";
import type { IntentType } from "@seed/schema";
import { usePersona } from "@/components/journey/PersonaProvider";
import { useSearch } from "@/lib/hooks/useSearch";
import { findItem, type ResolvedItem } from "@/lib/seedRuntime";
import { ItemTile } from "@/components/tiles/ItemTile";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ToolStatusPill } from "@/components/primitives/ToolStatusPill";
import { INTENT_META } from "@/components/primitives/IntentChip";
import { cn } from "@/lib/cn";

/*
 * S4 검색 씬 — "뭐라고 저장했는지 기억 안 나도" 자연어로 다시 찾는다.
 * idle 은 전체 모자이크(브라우징), 제출 시 의미검색 → AnswerCard + 근거 리플로우.
 */

const SCOPES: Array<{ key: IntentType | "all"; label: string }> = [
  { key: "all", label: "전체" },
  { key: "schedule", label: "일정" },
  { key: "todo", label: "할일" },
  { key: "knowledge", label: "지식" },
  { key: "memo", label: "기록" },
];

export function SearchScene() {
  const { persona, items, now } = usePersona();
  const knownSlugs = useMemo(() => new Set(items.map((i) => i.slug)), [items]);
  const search = useSearch(persona.slug, knownSlugs);
  const [input, setInput] = useState("");
  const [scope, setScope] = useState<IntentType | "all">("all");

  const submit = (q: string) => {
    setInput(q);
    void search.run(q);
  };

  const inScope = (item: ResolvedItem) =>
    scope === "all" || item.instances.some((x) => x.intentType === scope);

  const resultItems =
    search.status === "done"
      ? search.slugs
          .map((s) => findItem(items, s))
          .filter((x): x is ResolvedItem => Boolean(x))
          .filter(inScope)
      : [];

  const idleItems = items.filter(inScope);
  const showResults = search.status === "done" || search.status === "loading";

  return (
    <main className="mx-auto max-w-6xl px-5 py-8">
      <RiseIn index={0}>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            submit(input);
          }}
          className="mx-auto flex max-w-2xl items-center gap-3 rounded-[22px] border border-ink-100 bg-surface py-1.5 pl-5 pr-2 shadow-card focus-within:border-purple-200"
        >
          <Search className="size-4.5 flex-none text-ink-300" aria-hidden />
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="기억나는 대로 검색해보세요 — 정확하지 않아도 돼요"
            aria-label="기록 검색"
            className="min-w-0 flex-1 bg-transparent py-2.5 text-[14.5px] outline-none placeholder:text-ink-300"
          />
          {search.status !== "idle" && (
            <button
              type="button"
              onClick={() => {
                setInput("");
                search.reset();
              }}
              className="flex-none rounded-full px-3 py-1.5 text-[12.5px] font-semibold text-ink-500 hover:text-ink-900"
            >
              지우기
            </button>
          )}
        </form>
      </RiseIn>

      <RiseIn index={1}>
        <div className="mt-3.5 flex flex-wrap items-center justify-center gap-2">
          {persona.suggestedSearch.map((q) => (
            <button
              key={q}
              onClick={() => submit(q)}
              className="rounded-full border border-purple-100 bg-purple-50 px-3.5 py-2 text-[13px] font-semibold text-purple-600 transition-transform active:scale-[0.97]"
            >
              {q}
            </button>
          ))}
        </div>
      </RiseIn>

      <RiseIn index={2}>
        <div className="mt-6 flex items-center justify-between gap-3">
          <h1 className="text-[17px] font-extrabold tracking-snug">
            {showResults ? "찾아온 기록" : "모든 기록"}
          </h1>
          <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1" role="group" aria-label="종류 필터">
            {SCOPES.map(({ key, label }) => {
              const active = scope === key;
              const meta = key !== "all" ? INTENT_META[key] : null;
              return (
                <button
                  key={key}
                  onClick={() => setScope(key)}
                  aria-pressed={active}
                  className={cn(
                    "flex flex-none items-center gap-1.5 rounded-full border px-3 py-1.5 text-[12.5px] font-semibold transition-colors",
                    active
                      ? "border-ink-900 bg-ink-900 text-white"
                      : "border-ink-100 bg-surface text-ink-500 hover:text-ink-900",
                  )}
                >
                  {meta && (
                    <meta.Icon
                      className={cn("size-3.5", active ? "text-white" : meta.dot)}
                      strokeWidth={2.4}
                      aria-hidden
                    />
                  )}
                  {label}
                </button>
              );
            })}
          </div>
        </div>
      </RiseIn>

      <div aria-live="polite">
        <AnimatePresence mode="wait" initial={false}>
          {search.status === "loading" && (
            <motion.div
              key="loading"
              className="flex justify-center py-14"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
            >
              <ToolStatusPill label="기록을 뒤지고 있어요…" />
            </motion.div>
          )}

          {search.status === "done" && (
            <motion.div
              key={`ans-${search.query}`}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              transition={{ type: "spring", duration: 0.45, bounce: 0 }}
              className="mt-4"
            >
              <div className="rounded-2xl border border-ink-100 bg-surface p-5 shadow-card">
                <p className="flex items-center gap-2 text-[12.5px] font-bold text-ink-500">
                  <Image src="/brand/mochi2.png" alt="" width={18} height={18} aria-hidden />
                  모찌의 답
                </p>
                <p className="mt-2 text-[15px] leading-relaxed [text-wrap:pretty]">
                  <Highlight text={search.answer} query={search.query} />
                </p>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {search.status === "done" && resultItems.length === 0 ? (
        <div className="flex flex-col items-center py-14 text-center">
          <Image
            src="/brand/mochi-question.png"
            alt=""
            width={84}
            height={84}
            className="h-[72px] w-auto"
          />
          <p className="mt-3 text-[16px] font-bold">찾는 기록이 없어요</p>
          <p className="mt-1 text-[13px] text-ink-500">
            말을 바꿔 다시 찾거나, 모찌에게 직접 물어보세요
          </p>
          <Link
            href={`/p/${persona.slug}/chat?q=${encodeURIComponent(search.query)}`}
            className="mt-4 inline-flex h-10 items-center rounded-full bg-ink-900 px-5 text-[13.5px] font-bold text-white"
          >
            모찌에게 물어보기
          </Link>
        </div>
      ) : (
        <motion.div
          layout
          className="mt-5 columns-2 gap-4 md:columns-4 [&>*]:mb-4 [&>*]:break-inside-avoid"
        >
          {(showResults ? resultItems : idleItems).map((item) => (
            <ItemTile
              key={item.slug}
              item={item}
              now={now}
              href={`/p/${persona.slug}/items/${item.slug}`}
            />
          ))}
        </motion.div>
      )}
    </main>
  );
}

/** 검색어 토큰을 butter 하이라이트 (iOS 규칙) */
function Highlight({ text, query }: { text: string; query: string }) {
  const tokens = query
    .toLowerCase()
    .split(/\s+/)
    .filter((t) => t.length > 1);
  if (tokens.length === 0) return <>{text}</>;

  const re = new RegExp(
    `(${tokens.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`,
    "gi",
  );
  return (
    <>
      {text.split(re).map((part, i) =>
        re.test(part) ? (
          <mark key={i} className="rounded-sm bg-butter-100 px-0.5 text-ink-900">
            {part}
          </mark>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
}
