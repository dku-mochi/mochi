"use client";

import { useCallback, useRef, useState } from "react";
import type { AnalysisWireEvent, AnalyzedItemWire } from "@/lib/api/wire";
import { parseSseStream, toTagged } from "@/lib/sse/parse";

/*
 * S2 라이브 분석 훅 — ingest → 진행 SSE(node…final) → 본문 재조회.
 * iOS 규약 그대로: 분석 본문은 스트림에 실리지 않는다.
 */

export type AnalysisStage =
  | "idle"
  | "sending"
  | "ingested"
  | "normalized"
  | "analyzing"
  | "done"
  | "failed";

export const STAGE_LABEL: Record<Exclude<AnalysisStage, "idle" | "done" | "failed">, string> = {
  sending: "모찌에게 보내는 중…",
  ingested: "받았어요 — 읽고 있어요…",
  normalized: "내용을 간추리고 있어요…",
  analyzing: "무엇을 해둘지 정하고 있어요…",
};

export function useLiveAnalysis(personaSlug: string) {
  const [stage, setStage] = useState<AnalysisStage>("idle");
  const [result, setResult] = useState<AnalyzedItemWire | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const run = useCallback(
    async (input: { text?: string; url?: string; memo?: string }) => {
      if (stage !== "idle" && stage !== "done" && stage !== "failed") return;
      setResult(null);
      setStage("sending");
      const ac = new AbortController();
      abortRef.current = ac;

      try {
        const ingest = await fetch("/api/bff/ingest", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ...input, persona: personaSlug }),
          signal: ac.signal,
        });
        if (!ingest.ok) throw new Error(`ingest_http_${ingest.status}`);
        const { id } = (await ingest.json()) as { id: string };

        const stream = await fetch(`/api/bff/ingest/${encodeURIComponent(id)}/stream`, {
          signal: ac.signal,
        });
        if (!stream.ok || !stream.body) throw new Error(`stream_http_${stream.status}`);

        for await (const raw of parseSseStream(stream.body, ac.signal)) {
          const e = toTagged<AnalysisWireEvent>(raw);
          if (!e) continue;
          if (e.kind === "node") {
            const k = e.lifecycle_kind as AnalysisStage;
            if (k === "ingested" || k === "normalized" || k === "analyzing") setStage(k);
          } else if (e.kind === "final") {
            break;
          } else if (e.kind === "failed") {
            throw new Error(e.message);
          }
        }

        // final 수신 → 본문 재조회 (iOS 와 같은 순서)
        const item = await fetch(`/api/bff/items/${encodeURIComponent(id)}`, {
          signal: ac.signal,
        });
        if (!item.ok) throw new Error(`item_http_${item.status}`);
        setResult((await item.json()) as AnalyzedItemWire);
        setStage("done");
      } catch (err) {
        if ((err as Error).name !== "AbortError") setStage("failed");
      } finally {
        abortRef.current = null;
      }
    },
    [personaSlug, stage],
  );

  const reset = useCallback(() => {
    abortRef.current?.abort();
    setStage("idle");
    setResult(null);
  }, []);

  return { stage, result, run, reset };
}
