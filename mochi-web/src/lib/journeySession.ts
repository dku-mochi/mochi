"use client";

import { useSyncExternalStore } from "react";
import { clearAllLiveCaptures } from "@/lib/liveOverlay";
import { resetStats } from "@/lib/liveStats";

export const JOURNEY_STEPS = ["capture", "home", "search", "chat", "recall"] as const;
export type JourneyStep = (typeof JOURNEY_STEPS)[number];
export type JourneyStepStatus = "pending" | "completed" | "skipped";

interface StepState {
  status: JourneyStepStatus;
  at?: number;
}

export interface JourneySession {
  id: string;
  personaSlug: string;
  startedAt: number;
  steps: Record<JourneyStep, StepState>;
  capture?: { slug: string; title: string };
  proposal?: "confirmed" | "preview";
}

const KEY = "mochi-journey";
const RESET_PREFIXES = ["mochi-conv-", "mochi-guided-step-", "mochi-spotlight-"];
let cache: JourneySession | null | undefined;
const listeners = new Set<() => void>();

function blankSteps(): JourneySession["steps"] {
  return Object.fromEntries(
    JOURNEY_STEPS.map((step) => [step, { status: "pending" }]),
  ) as JourneySession["steps"];
}

function isSession(value: unknown): value is JourneySession {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<JourneySession>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.personaSlug === "string" &&
    typeof candidate.startedAt === "number" &&
    !!candidate.steps &&
    JOURNEY_STEPS.every((step) => {
      const status = candidate.steps?.[step]?.status;
      return status === "pending" || status === "completed" || status === "skipped";
    })
  );
}

function readStored(): JourneySession | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as unknown;
    return isSession(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function publish(next: JourneySession | null): void {
  cache = next;
  try {
    if (next) sessionStorage.setItem(KEY, JSON.stringify(next));
    else sessionStorage.removeItem(KEY);
  } catch {
    /* 스토리지 불가 환경에서도 현재 페이지 메모리 상태는 유지한다 */
  }
  listeners.forEach((listener) => listener());
}

export function getJourneySession(): JourneySession | null {
  if (typeof window === "undefined") return null;
  if (cache === undefined) cache = readStored();
  return cache;
}

export function getServerJourneySession(): JourneySession | null {
  return null;
}

export function subscribeJourneySession(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useJourneySession(): JourneySession | null {
  return useSyncExternalStore(
    subscribeJourneySession,
    getJourneySession,
    getServerJourneySession,
  );
}

function removeJourneyResidue(): void {
  for (let i = sessionStorage.length - 1; i >= 0; i--) {
    const key = sessionStorage.key(i);
    if (key && RESET_PREFIXES.some((prefix) => key.startsWith(prefix))) {
      sessionStorage.removeItem(key);
    }
  }
  clearAllLiveCaptures();
  resetStats();
}

export function startJourney(personaSlug: string): JourneySession {
  removeJourneyResidue();
  const next: JourneySession = {
    id: crypto.randomUUID(),
    personaSlug,
    startedAt: Date.now(),
    steps: blankSteps(),
  };
  publish(next);
  return next;
}

export function ensureJourney(personaSlug: string): JourneySession {
  const current = getJourneySession();
  if (current?.personaSlug === personaSlug) return current;
  const next: JourneySession = {
    id: crypto.randomUUID(),
    personaSlug,
    startedAt: Date.now(),
    steps: blankSteps(),
  };
  publish(next);
  return next;
}

export function markJourneyStep(
  personaSlug: string,
  step: JourneyStep,
  detail?: { capture?: JourneySession["capture"]; proposal?: JourneySession["proposal"] },
): void {
  const current = ensureJourney(personaSlug);
  const next: JourneySession = {
    ...current,
    steps: {
      ...current.steps,
      [step]: { status: "completed", at: Date.now() },
    },
    ...(detail?.capture ? { capture: detail.capture } : {}),
    ...(detail?.proposal ? { proposal: detail.proposal } : {}),
  };
  publish(next);
}

export function markProposalExperience(
  personaSlug: string,
  proposal: NonNullable<JourneySession["proposal"]>,
): void {
  const current = ensureJourney(personaSlug);
  publish({ ...current, proposal });
}

export function skipJourneyStep(personaSlug: string, step: JourneyStep): void {
  const current = ensureJourney(personaSlug);
  if (current.steps[step].status === "completed") return;
  publish({
    ...current,
    steps: {
      ...current.steps,
      [step]: { status: "skipped", at: Date.now() },
    },
  });
}
