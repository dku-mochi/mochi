import { describe, expect, it } from "vitest";
import type { SeedPersona } from "@seed/schema";
import {
  resolveItems,
  activeTodos,
  calendarEntries,
  relativeLabel,
  dday,
  monthlyReport,
  kstParts,
} from "./seedRuntime";

/* 2026-07-07 (화) 15:00 KST 고정 — 러너 타임존과 무관하게 UTC 로 구성 */
const NOW = Date.UTC(2026, 6, 7, 6, 0, 0);
const DAY = 86_400_000;

const persona = {
  slug: "test",
  items: [
    {
      slug: "a",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "일정+할일 복합",
      category: "테스트",
      summary: "s",
      capturedDaysAgo: 2,
      instances: [
        { intentType: "todo", payload: { title: "할일", deadlineInDays: 5 } },
        { intentType: "schedule", payload: { title: "일정", dateInDays: 3 } },
      ],
    },
    {
      slug: "b",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "급한 할일",
      category: "테스트",
      summary: "s",
      capturedDaysAgo: 0.5,
      instances: [{ intentType: "todo", payload: { title: "급함", deadlineInDays: 1 } }],
    },
    {
      slug: "c",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "지식",
      category: "테스트",
      summary: "s",
      capturedDaysAgo: 40,
      instances: [{ intentType: "knowledge" }],
    },
  ],
} as unknown as SeedPersona;

describe("resolveItems", () => {
  const items = resolveItems(persona, NOW);

  it("최근 캡처 순 정렬", () => {
    expect(items.map((i) => i.slug)).toEqual(["b", "a", "c"]);
  });

  it("대표 intent 는 iOS 고정 우선순위 (schedule > todo > knowledge > memo)", () => {
    expect(items.find((i) => i.slug === "a")!.primaryIntent).toBe("schedule");
    expect(items.find((i) => i.slug === "c")!.primaryIntent).toBe("knowledge");
  });

  it("상대 마감이 KST 자정 기준 절대 시각으로 풀린다", () => {
    const a = items.find((i) => i.slug === "a")!;
    const due = a.instances.find((x) => x.intentType === "todo")!.dueAt!;
    const p = kstParts(due);
    expect([p.month, p.day, p.hours]).toEqual([7, 12, 0]);
  });
});

describe("파생 셀렉터", () => {
  const items = resolveItems(persona, NOW);

  it("activeTodos 는 마감 임박순", () => {
    expect(activeTodos(items).map((t) => t.item.slug)).toEqual(["b", "a"]);
  });

  it("calendarEntries — 일자별 일정/마감/저장 항목", () => {
    const map = calendarEntries(items, 2026, 7);
    const kindsAt = (d: number) => (map.get(d) ?? []).map((e) => e.kind);
    expect(kindsAt(10)).toEqual(["schedule"]); // 7/7 + 3일
    expect(kindsAt(12)).toEqual(["deadline"]); // 7/7 + 5일
    expect(kindsAt(8)).toEqual(["deadline"]); // 급한 할일 D+1
    expect(kindsAt(7)).toEqual(["saved"]); // b (12시간 전)
    expect(kindsAt(5)).toEqual(["saved"]); // a (2일 전)
  });

  it("calendarEntries kinds 필터 — 기록 보드는 저장 점을 뺀다", () => {
    const map = calendarEntries(items, 2026, 7, ["schedule", "deadline"]);
    const all = [...map.values()].flat();
    expect(all.length).toBeGreaterThan(0);
    expect(all.every((e) => e.kind !== "saved")).toBe(true);
  });

  it("monthlyReport 는 이번 달 캡처만 센다", () => {
    const r = monthlyReport(items, NOW);
    expect(r.total).toBe(2); // c 는 5월
    expect(r.byIntent.schedule).toBe(1);
    expect(r.byIntent.todo).toBe(1);
  });
});

describe("표시 포맷", () => {
  it("relativeLabel", () => {
    expect(relativeLabel(NOW - 30 * 60_000, NOW)).toBe("방금 전");
    expect(relativeLabel(NOW - 5 * 3_600_000, NOW)).toBe("5시간 전");
    expect(relativeLabel(NOW - 1 * DAY, NOW)).toBe("어제");
    expect(relativeLabel(NOW - 3 * DAY, NOW)).toBe("3일 전");
    expect(relativeLabel(NOW - 10 * DAY, NOW)).toBe("1주 전");
  });

  it("dday", () => {
    expect(dday(NOW, NOW)).toBe("오늘");
    expect(dday(NOW + DAY, NOW)).toBe("내일");
    expect(dday(NOW + 5 * DAY, NOW)).toBe("D-5");
    expect(dday(NOW - 2 * DAY, NOW)).toBe("2일 지남");
  });
});
