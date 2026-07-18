"use client";

import Link from "next/link";
import { useEffect } from "react";
import { ArrowUpRight, Sparkles } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import { IntentChip } from "@/components/primitives/IntentChip";
import { markJourneyStep } from "@/lib/journeySession";

export function LatestCaptureSummary() {
  const { persona, liveItems } = usePersona();
  const latest = liveItems[0];

  useEffect(() => {
    if (!latest) return;
    markJourneyStep(persona.slug, "home");
  }, [latest, persona.slug]);

  if (!latest) return null;
  const intents = [...new Set(latest.instances.map((instance) => instance.intentType))];

  return (
    <section
      className="border-y border-purple-100 bg-purple-50/45 px-1 py-4"
      aria-label="방금 보낸 기록"
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <span className="flex size-9 flex-none items-center justify-center rounded-xl bg-surface text-purple-500 shadow-card">
          <Sparkles className="size-4" aria-hidden />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-[11.5px] font-bold text-purple-600">방금 보낸 기록이 도착했어요</p>
          <p className="mt-0.5 truncate text-[14.5px] font-extrabold text-ink-900">{latest.title}</p>
          <p className="mt-0.5 line-clamp-1 text-[12.5px] text-ink-500">{latest.summary}</p>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          {intents.slice(0, 2).map((intent) => (
            <IntentChip key={intent} intent={intent} size="sm" />
          ))}
          <Link
            href={`/p/${persona.slug}/items/${latest.slug}`}
            className="ml-1 inline-flex h-9 items-center gap-1 rounded-full bg-ink-900 px-4 text-[12.5px] font-bold text-white transition-transform active:scale-[0.97]"
          >
            자세히 보기 <ArrowUpRight className="size-3.5" aria-hidden />
          </Link>
        </div>
      </div>
    </section>
  );
}
