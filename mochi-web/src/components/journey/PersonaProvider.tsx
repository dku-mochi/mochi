"use client";

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useReducer,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import type { SeedPersona } from "@seed/schema";
import { resolveItems, type ResolvedItem } from "@/lib/seedRuntime";
import {
  addLiveCapture as addLiveCaptureToStore,
  getLiveCaptures,
  getServerLiveCaptures,
  resolveLiveCaptures,
  subscribeLiveCaptures,
  type LiveCaptureEntry,
} from "@/lib/liveOverlay";

/*
 * 페르소나 씬 공유 상태 — 시드는 불변, 심사위원 상호작용만 로컬 오버레이.
 * 오버레이 2종: 할일 체크(todoDone), 이 브라우저에서 라이브로 보낸 기록(liveCaptures).
 * 라이브 기록은 sessionStorage 에 살아 홈·검색·캘린더에 "내 것만" 합성된다 —
 * 페르소나 백엔드 계정은 공유라서, 남이 보낸 기록은 절대 화면에 얹지 않는다.
 * `now` 는 서버에서 요청당 1회 주입 (하이드레이션 일치).
 */

interface Interactions {
  /** `${itemSlug}:${instanceIndex}` → done 오버라이드 */
  todoDone: Record<string, boolean>;
}

type Action = { type: "toggleTodo"; key: string; base: boolean };

function reducer(state: Interactions, action: Action): Interactions {
  switch (action.type) {
    case "toggleTodo": {
      const cur = state.todoDone[action.key] ?? action.base;
      return { ...state, todoDone: { ...state.todoDone, [action.key]: !cur } };
    }
  }
}

interface PersonaContextValue {
  persona: SeedPersona;
  now: number;
  /** 시드 + 이 세션의 라이브 기록 (최신순) */
  items: ResolvedItem[];
  /** 이 브라우저 세션에서 라이브로 보낸 기록 (최신순) */
  liveItems: ResolvedItem[];
  liveSlugs: Set<string>;
  /** 라이브 wire id(uuid) → 오버레이 slug — 검색 citation 을 내 기록 타일로 되살린다 */
  liveIdToSlug: Map<string, string>;
  addLiveCapture: (entry: LiveCaptureEntry) => void;
  isTodoDone: (itemSlug: string, instanceIndex: number, base: boolean) => boolean;
  toggleTodo: (itemSlug: string, instanceIndex: number, base: boolean) => void;
}

const PersonaContext = createContext<PersonaContextValue | null>(null);

export function PersonaProvider({
  persona,
  now,
  children,
}: {
  persona: SeedPersona;
  now: number;
  children: ReactNode;
}) {
  const [interactions, dispatch] = useReducer(reducer, { todoDone: {} });
  // SSR/하이드레이션은 항상 시드만 — 마운트 후 sessionStorage 스냅숏으로 교체
  const liveEntries = useSyncExternalStore(
    useCallback((fn: () => void) => subscribeLiveCaptures(persona.slug, fn), [persona.slug]),
    useCallback(() => getLiveCaptures(persona.slug), [persona.slug]),
    getServerLiveCaptures,
  );

  const addLiveCapture = useCallback(
    (entry: LiveCaptureEntry) => addLiveCaptureToStore(persona.slug, entry),
    [persona.slug],
  );

  const seedItems = useMemo(() => resolveItems(persona, now), [persona, now]);
  const liveItems = useMemo(() => resolveLiveCaptures(liveEntries), [liveEntries]);
  const items = useMemo(
    () =>
      [...liveItems, ...seedItems].sort((a, b) => b.capturedAt - a.capturedAt),
    [liveItems, seedItems],
  );
  const liveSlugs = useMemo(
    () => new Set(liveItems.map((i) => i.slug)),
    [liveItems],
  );
  const liveIdToSlug = useMemo(
    () => new Map(liveEntries.map((e) => [e.wire.id, e.slug])),
    [liveEntries],
  );

  const value = useMemo<PersonaContextValue>(
    () => ({
      persona,
      now,
      items,
      liveItems,
      liveSlugs,
      liveIdToSlug,
      addLiveCapture,
      isTodoDone: (slug, idx, base) =>
        interactions.todoDone[`${slug}:${idx}`] ?? base,
      toggleTodo: (slug, idx, base) =>
        dispatch({ type: "toggleTodo", key: `${slug}:${idx}`, base }),
    }),
    [persona, now, items, liveItems, liveSlugs, liveIdToSlug, addLiveCapture, interactions],
  );

  return (
    <PersonaContext.Provider value={value}>{children}</PersonaContext.Provider>
  );
}

export function usePersona(): PersonaContextValue {
  const ctx = useContext(PersonaContext);
  if (!ctx) throw new Error("usePersona must be used within PersonaProvider");
  return ctx;
}
