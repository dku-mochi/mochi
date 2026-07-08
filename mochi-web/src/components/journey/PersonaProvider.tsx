"use client";

import {
  createContext,
  useContext,
  useMemo,
  useReducer,
  type ReactNode,
} from "react";
import type { SeedPersona } from "@seed/schema";
import { resolveItems, type ResolvedItem } from "@/lib/seedRuntime";

/*
 * 페르소나 씬 공유 상태 — 시드는 불변, 심사위원 상호작용(할일 체크 등)만 로컬 오버레이.
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
  items: ResolvedItem[];
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
  const items = useMemo(() => resolveItems(persona, now), [persona, now]);

  const value = useMemo<PersonaContextValue>(
    () => ({
      persona,
      now,
      items,
      isTodoDone: (slug, idx, base) =>
        interactions.todoDone[`${slug}:${idx}`] ?? base,
      toggleTodo: (slug, idx, base) =>
        dispatch({ type: "toggleTodo", key: `${slug}:${idx}`, base }),
    }),
    [persona, now, items, interactions],
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
