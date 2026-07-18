"use client";

import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Search, Sparkles } from "lucide-react";
import type { IntentType } from "@seed/schema";
import { usePersona } from "@/components/journey/PersonaProvider";
import { useSearch } from "@/lib/hooks/useSearch";
import { resolveItemSlug } from "@/lib/hooks/useChatStream";
import { retrievalSuggestionsFor } from "@/lib/retrievalSuggestions";
import { findItem, type ResolvedItem } from "@/lib/seedRuntime";
import { ItemTile } from "@/components/tiles/ItemTile";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ToolStatusPill } from "@/components/primitives/ToolStatusPill";
import { INTENT_META } from "@/components/primitives/IntentChip";
import { cn } from "@/lib/cn";
import { markJourneyStep } from "@/lib/journeySession";

/*
 * S4 검색 씬 — "뭐라고 저장했는지 기억 안 나도" 자연어로 다시 찾는다.
 * 검색의 답은 기록 타일이다: 문구 일치(literal)를 앞세우고 의미검색(citations)으로
 * 보강한다 — iOS SearchFeature 와 같은 규칙. 문장 답변은 채팅(S5)의 몫.
 */

const SCOPES: Array<{ key: IntentType | "all"; label: string }> = [
  { key: "all", label: "전체" },
  { key: "schedule", label: "일정" },
  { key: "todo", label: "할일" },
  { key: "knowledge", label: "지식" },
  { key: "memo", label: "기록" },
];

/** 문구 일치 — 토큰 부분일치 수로 점수화 (폴백 엔진과 같은 규칙, 클라 즉시 실행) */
function literalMatch(items: ResolvedItem[], query: string): string[] {
  const tokens = query
    .toLowerCase()
    .split(/\s+/)
    .filter((t) => t.length > 1);
  if (tokens.length === 0) return [];
  return items
    .map((item) => {
      const hay = [
        item.title,
        item.retrievalHint ?? "",
        item.summary,
        item.category,
        item.ocrText ?? "",
        item.text ?? "",
        item.userMemo ?? "",
      ]
        .join(" ")
        .toLowerCase();
      return { slug: item.slug, score: tokens.reduce((n, t) => (hay.includes(t) ? n + 1 : n), 0) };
    })
    .filter((h) => h.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((h) => h.slug);
}

export function SearchScene() {
  const { persona, items, liveItems, liveIdToSlug, liveSlugs, now } = usePersona();
  const knownSlugs = useMemo(() => new Set(items.map((i) => i.slug)), [items]);

  // citation id 해석 — 시드 uuid 매핑에 더해, 이 세션의 내 라이브 기록도 되살린다.
  // 매핑에 없는 id(다른 방문자의 기록)는 버려진다.
  const resolveSlug = useCallback(
    (id: string) => resolveItemSlug(id, knownSlugs) ?? liveIdToSlug.get(id) ?? null,
    [knownSlugs, liveIdToSlug],
  );
  const search = useSearch(persona.slug, resolveSlug);
  const [input, setInput] = useState("");
  const [scope, setScope] = useState<IntentType | "all">("all");
  const latest = liveItems[0];
  const recentRetrieval = useMemo(
    () => (latest ? retrievalSuggestionsFor(latest).search : null),
    [latest],
  );
  const liveContext = useMemo(() => {
    if (!latest) return undefined;
    const id = [...liveIdToSlug].find(([, slug]) => slug === latest.slug)?.[0];
    return id ? { id, title: latest.title, summary: latest.summary } : undefined;
  }, [latest, liveIdToSlug]);
  const suggestions = useMemo(
    () => [
      ...(recentRetrieval
        ? [{ ...recentRetrieval, recent: true }]
        : []),
      ...persona.suggestedSearch.map((query) => ({ label: query, query, recent: false })),
    ],
    [recentRetrieval, persona.suggestedSearch],
  );

  const submit = (q: string, recent = false) => {
    setInput(q);
    void search.run(q, recent ? liveContext : undefined);
  };

  const inScope = (item: ResolvedItem) =>
    scope === "all" || item.instances.some((x) => x.intentType === scope);

  // literal 우선 + semantic 추가 (중복 제거) — 오류 시에도 literal 은 성립한다
  const mergedSlugs = useMemo(() => {
    if (search.status !== "done" && search.status !== "error") return [];
    return [...new Set([...literalMatch(items, search.query), ...search.slugs])];
  }, [search.status, search.query, search.slugs, items]);

  const resultItems = mergedSlugs
    .map((s) => findItem(items, s))
    .filter((x): x is ResolvedItem => Boolean(x))
    .filter(inScope);

  const idleItems = items.filter(inScope);
  const settled = search.status === "done" || search.status === "error";
  const showResults = settled || search.status === "loading";

  useEffect(() => {
    if (!settled || !search.query.trim()) return;
    markJourneyStep(persona.slug, "search");
  }, [persona.slug, search.query, settled]);

  // 결과 중 모찌가 이미 먼저 떠올려둔 것 — 리마인드(클라이맥스)를 미리 심는다
  const recallSlugs = useMemo(
    () => new Set([...persona.recall.map((r) => r.itemSlug), ...liveSlugs]),
    [liveSlugs, persona.recall],
  );
  const rememberedCount = resultItems.filter((i) => recallSlugs.has(i.slug)).length;

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
            placeholder="기억나는 대로 검색해보세요. 정확하지 않아도 돼요"
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
          {suggestions.map((suggestion) => (
            <button
              key={`${suggestion.recent ? "recent" : "seed"}-${suggestion.query}`}
              onClick={() => submit(suggestion.query, suggestion.recent)}
              className={cn(
                "inline-flex items-center gap-1.5 rounded-full border px-3.5 py-2 text-[13px] font-semibold transition-[background-color,border-color,transform] active:scale-[0.97]",
                suggestion.recent
                  ? "border-purple-300 bg-purple-600 text-white shadow-card hover:bg-purple-500"
                  : "border-purple-100 bg-purple-50 text-purple-600 hover:border-purple-200 hover:bg-purple-100",
              )}
            >
              {suggestion.recent && <Sparkles className="size-3.5" aria-hidden />}
              {suggestion.label}
            </button>
          ))}
        </div>
      </RiseIn>

      <RiseIn index={2}>
        <div className="mt-6 flex items-center justify-between gap-3">
          <h1 className="flex items-baseline gap-2 text-[17px] font-extrabold tracking-snug">
            {showResults ? "찾아온 기록" : "모든 기록"}
            {settled && (
              <span className="text-[13px] font-bold text-ink-500 tnum">
                {resultItems.length}건
              </span>
            )}
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

          {search.status === "error" && (
            <motion.p
              key="error"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              className="mt-4 rounded-2xl border border-ink-100 bg-surface px-4 py-3 text-[13px] font-medium text-ink-500 shadow-card"
            >
              연결이 잠시 고르지 않아요. 문구가 일치하는 기록부터 보여드릴게요.
            </motion.p>
          )}

          {search.status === "done" && rememberedCount > 0 && (
            <motion.div
              key={`recall-${search.query}`}
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              transition={{ type: "spring", duration: 0.45, bounce: 0 }}
              className="mt-4 flex items-center gap-2.5 rounded-2xl border border-purple-100 bg-purple-50/70 px-4 py-3"
            >
              <Sparkles className="size-4 flex-none text-purple-500" aria-hidden />
              <p className="min-w-0 text-[13px] font-medium text-ink-700">
                이 중 <b className="font-bold text-purple-600">{rememberedCount}건</b>은 찾기 전에
                모찌가 이미 떠올려뒀어요.{" "}
                <Link
                  href={`/p/${persona.slug}/recall`}
                  className="font-bold text-purple-600 underline-offset-2 hover:underline"
                >
                  리마인드 보기
                </Link>
              </p>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {settled && resultItems.length === 0 ? (
        <div className="flex flex-col items-center py-14 text-center">
          <Image
            src="/brand/mochi-question.png"
            alt=""
            width={84}
            height={84}
            className="h-[76px] w-auto"
          />
          <p className="mt-3 text-[16px] font-bold">찾는 기록이 없어요</p>
          <p className="mt-1 text-[13px] text-ink-500">
            말을 바꿔 다시 찾거나, 모찌에게 직접 물어보세요
          </p>
          <Link
            href={`/p/${persona.slug}/chat?q=${encodeURIComponent(search.query)}`}
            className="mt-4 inline-flex h-10 items-center rounded-full bg-ink-900 px-5 text-[13.5px] font-bold text-white transition-colors hover:bg-ink-700"
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
              highlight={!showResults && liveSlugs.has(item.slug)}
            />
          ))}
        </motion.div>
      )}
    </main>
  );
}
