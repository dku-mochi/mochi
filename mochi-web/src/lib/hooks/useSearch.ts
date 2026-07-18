"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { SearchWireResponse } from "@/lib/api/wire";
import { recordMode } from "@/lib/liveStats";

/*
 * 검색 훅 — POST /api/bff/search 의 citations 만 소비한다.
 * 문장 답변은 채팅(S5)의 역할 — /search 계약에서 answer 필드가 제거됐다 (iOS 와 동일).
 * citation id → 시드/오버레이 slug 해석은 호출부가 resolver 로 주입한다.
 */

export interface SearchState {
  status: "idle" | "loading" | "done" | "error";
  query: string;
  /** 점수순 slug (해석 실패한 citation 은 버린다 — 남의 라이브 기록 차단) */
  slugs: string[];
}

export interface SearchLiveContext {
  id: string;
  title: string;
  summary: string;
}

const IDLE: SearchState = { status: "idle", query: "", slugs: [] };

export function useSearch(
  personaSlug: string,
  resolveSlug: (itemId: string) => string | null,
) {
  const [state, setState] = useState<SearchState>(IDLE);
  const seqRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => () => abortRef.current?.abort(), []);

  const run = useCallback(
    async (query: string, liveContext?: SearchLiveContext) => {
      const q = query.trim();
      if (!q) return;
      const seq = ++seqRef.current;
      abortRef.current?.abort(); // 이전 질의 정리 — 늦은 응답이 서버를 점유하지 않게
      const ac = new AbortController();
      abortRef.current = ac;
      setState({ status: "loading", query: q, slugs: [] });
      try {
        const res = await fetch("/api/bff/search", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ query: q, persona: personaSlug, liveContext }),
          signal: ac.signal,
        });
        if (!res.ok) throw new Error(`search_http_${res.status}`);
        recordMode(res.headers.get("x-mochi-mode"));
        const data = (await res.json()) as SearchWireResponse;
        if (seq !== seqRef.current) return; // 늦게 도착한 이전 질의 무시
        const slugs = [
          ...new Set(
            data.citations
              .map((c) => resolveSlug(c.mochiItemId))
              .filter((s): s is string => Boolean(s)),
          ),
        ];
        setState({ status: "done", query: q, slugs });
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
        if (seq !== seqRef.current) return;
        setState({ status: "error", query: q, slugs: [] });
      }
    },
    [personaSlug, resolveSlug],
  );

  const reset = useCallback(() => setState(IDLE), []);

  return { ...state, run, reset };
}
