"use client";

import { useCallback, useRef, useState } from "react";
import type { SearchWireResponse } from "@/lib/api/wire";
import { resolveItemSlug } from "./useChatStream";

/* 검색 훅 — POST /api/bff/search. citations 의 id 를 로컬 시드 slug 로 해석해 타일로 렌더. */

export interface SearchState {
  status: "idle" | "loading" | "done" | "error";
  query: string;
  answer: string;
  /** 점수순 시드 slug */
  slugs: string[];
}

const IDLE: SearchState = { status: "idle", query: "", answer: "", slugs: [] };

export function useSearch(personaSlug: string, knownSlugs: Set<string>) {
  const [state, setState] = useState<SearchState>(IDLE);
  const seqRef = useRef(0);

  const run = useCallback(
    async (query: string) => {
      const q = query.trim();
      if (!q) return;
      const seq = ++seqRef.current;
      setState({ status: "loading", query: q, answer: "", slugs: [] });
      try {
        const res = await fetch("/api/bff/search", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ query: q, persona: personaSlug }),
        });
        if (!res.ok) throw new Error(`search_http_${res.status}`);
        const data = (await res.json()) as SearchWireResponse;
        if (seq !== seqRef.current) return; // 늦게 도착한 이전 질의 무시
        const slugs = data.citations
          .map((c) => resolveItemSlug(c.mochiItemID, knownSlugs))
          .filter((s): s is string => Boolean(s));
        setState({ status: "done", query: q, answer: data.answer, slugs });
      } catch {
        if (seq !== seqRef.current) return;
        setState({
          status: "error",
          query: q,
          answer: "검색이 잠시 고르지 않아요. 다시 시도해 주세요.",
          slugs: [],
        });
      }
    },
    [personaSlug, knownSlugs],
  );

  const reset = useCallback(() => setState(IDLE), []);

  return { ...state, run, reset };
}
