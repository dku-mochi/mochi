import { afterAll, beforeEach, describe, expect, it } from "vitest";
import {
  getJourneySession,
  markJourneyStep,
  skipJourneyStep,
  startJourney,
} from "./journeySession";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() { return this.values.size; }
  clear() { this.values.clear(); }
  getItem(key: string) { return this.values.get(key) ?? null; }
  key(index: number) { return [...this.values.keys()][index] ?? null; }
  removeItem(key: string) { this.values.delete(key); }
  setItem(key: string, value: string) { this.values.set(key, value); }
}

const originalWindow = globalThis.window;
const originalStorage = globalThis.sessionStorage;

beforeEach(() => {
  Object.defineProperty(globalThis, "window", { configurable: true, value: globalThis });
  Object.defineProperty(globalThis, "sessionStorage", {
    configurable: true,
    value: new MemoryStorage(),
  });
});

afterAll(() => {
  Object.defineProperty(globalThis, "window", { configurable: true, value: originalWindow });
  Object.defineProperty(globalThis, "sessionStorage", {
    configurable: true,
    value: originalStorage,
  });
});

describe("journey session", () => {
  it("새 체험이 이전 방문자의 로컬 상태를 비운다", () => {
    sessionStorage.setItem("mochi-live-captures-sena", "old");
    sessionStorage.setItem("mochi-conv-sena", "old-conversation");
    sessionStorage.setItem("mochi-live-stats", "old-stats");

    const journey = startJourney("sena");

    expect(journey.personaSlug).toBe("sena");
    expect(Object.values(journey.steps).every((step) => step.status === "pending")).toBe(true);
    expect(sessionStorage.getItem("mochi-live-captures-sena")).toBeNull();
    expect(sessionStorage.getItem("mochi-conv-sena")).toBeNull();
    expect(sessionStorage.getItem("mochi-live-stats")).toBeNull();
  });

  it("완료와 명시적 건너뛰기를 구분한다", () => {
    startJourney("sena");
    markJourneyStep("sena", "capture", {
      capture: { slug: "live-1", title: "내 기록" },
    });
    skipJourneyStep("sena", "search");

    const journey = getJourneySession();
    expect(journey?.steps.capture.status).toBe("completed");
    expect(journey?.capture).toEqual({ slug: "live-1", title: "내 기록" });
    expect(journey?.steps.search.status).toBe("skipped");
    expect(journey?.steps.chat.status).toBe("pending");
  });

  it("안내 없이 시작한 체험도 이미 보낸 기록을 지우지 않는다", () => {
    sessionStorage.setItem("mochi-live-captures-sena", "keep-me");

    markJourneyStep("dohyun", "search");

    expect(sessionStorage.getItem("mochi-live-captures-sena")).toBe("keep-me");
    expect(getJourneySession()?.personaSlug).toBe("dohyun");
    expect(getJourneySession()?.steps.search.status).toBe("completed");
  });
});
