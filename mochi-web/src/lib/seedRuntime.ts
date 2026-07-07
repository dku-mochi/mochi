import type {
  IntentType,
  SeedInstance,
  SeedItem,
  SeedPersona,
} from "@seed/schema";

/*
 * 시드(상대 시간축) → 화면 데이터(절대 시각) 파생.
 * `now` 는 서버(RSC)에서 요청당 1회 계산해 내려보낸다 — 서버/클라 하이드레이션 불일치 방지.
 */

const DAY = 86_400_000;
const KST_OFFSET = 9 * 3_600_000;

/*
 * 모든 달력 계산은 Asia/Seoul 고정 — Vercel(UTC) SSR 과 심사위원 브라우저(KST)가
 * 같은 날짜를 보게 한다 (타임존 의존 시 하이드레이션 불일치·하루 밀림).
 * 구현: epoch 을 +9h 시프트한 뒤 getUTC* 로 읽는다.
 */
export interface KstParts {
  year: number;
  month: number; // 1-12
  day: number;
  weekday: number; // 0=일
  hours: number;
}

export function kstParts(ts: number): KstParts {
  const d = new Date(ts + KST_OFFSET);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    weekday: d.getUTCDay(),
    hours: d.getUTCHours(),
  };
}

export interface ResolvedInstance extends SeedInstance {
  /** schedule 시작일 or todo 마감일 (자정 기준) */
  dueAt?: number;
}

export interface ResolvedItem
  extends Omit<SeedItem, "instances" | "capturedDaysAgo"> {
  capturedAt: number;
  instances: ResolvedInstance[];
  /** iOS representativeIntent 규칙 — schedule > todo > knowledge > memo */
  primaryIntent: IntentType;
}

const INTENT_PRIORITY: IntentType[] = ["schedule", "todo", "knowledge", "memo"];

/** KST 자정의 epoch */
function midnight(now: number): number {
  const shifted = new Date(now + KST_OFFSET);
  shifted.setUTCHours(0, 0, 0, 0);
  return shifted.getTime() - KST_OFFSET;
}

export function resolveItems(persona: SeedPersona, now: number): ResolvedItem[] {
  const base = midnight(now);
  return persona.items
    .map((item) => {
      const instances: ResolvedInstance[] = item.instances.map((inst) => {
        const days = inst.payload?.dateInDays ?? inst.payload?.deadlineInDays;
        return { ...inst, dueAt: days === undefined ? undefined : base + days * DAY };
      });
      const primaryIntent =
        INTENT_PRIORITY.find((t) => instances.some((i) => i.intentType === t)) ??
        "memo";
      return {
        ...item,
        capturedAt: now - item.capturedDaysAgo * DAY,
        instances,
        primaryIntent,
      };
    })
    .sort((a, b) => b.capturedAt - a.capturedAt);
}

export function findItem(items: ResolvedItem[], slug: string) {
  return items.find((i) => i.slug === slug);
}

/* ── 홈 파생 ─────────────────────────────── */

/** 미완료 할일 — 마감 임박순 (마감 없는 것은 뒤로) */
export function activeTodos(items: ResolvedItem[]) {
  return items
    .flatMap((item) =>
      item.instances
        .filter((i) => i.intentType === "todo" && !i.done)
        .map((inst) => ({ item, inst })),
    )
    .sort((a, b) => (a.inst.dueAt ?? Infinity) - (b.inst.dueAt ?? Infinity));
}

export function doneTodos(items: ResolvedItem[]) {
  return items.flatMap((item) =>
    item.instances
      .filter((i) => i.intentType === "todo" && i.done)
      .map((inst) => ({ item, inst })),
  );
}

/** 다가올 일정 — 오늘 이후, 가까운 순 */
export function upcomingSchedules(items: ResolvedItem[], now: number) {
  const base = midnight(now);
  return items
    .flatMap((item) =>
      item.instances
        .filter(
          (i) =>
            i.intentType === "schedule" &&
            i.dueAt !== undefined &&
            i.dueAt >= base,
        )
        .map((inst) => ({ item, inst })),
    )
    .sort((a, b) => a.inst.dueAt! - b.inst.dueAt!);
}

/** 캘린더 점 3종 — sky=일정 · butter=마감 · purple=저장 (iOS 별도 팔레트 규약) */
export interface CalendarDay {
  schedule: number;
  deadline: number;
  saved: number;
}

export function calendarMap(
  items: ResolvedItem[],
  year: number,
  month: number, // 1-12
): Map<number, CalendarDay> {
  const map = new Map<number, CalendarDay>();
  const at = (ts: number) => {
    const p = kstParts(ts);
    if (p.year !== year || p.month !== month) return null;
    return p.day;
  };
  const bump = (day: number | null, key: keyof CalendarDay) => {
    if (day === null) return;
    const cur = map.get(day) ?? { schedule: 0, deadline: 0, saved: 0 };
    cur[key] += 1;
    map.set(day, cur);
  };
  for (const item of items) {
    bump(at(item.capturedAt), "saved");
    for (const inst of item.instances) {
      if (inst.dueAt === undefined) continue;
      if (inst.intentType === "schedule") bump(at(inst.dueAt), "schedule");
      if (inst.intentType === "todo" && !inst.done) bump(at(inst.dueAt), "deadline");
    }
  }
  return map;
}

/** LLM 자유형 카테고리 — 많은 순 (iOS 검색 필터 규칙) */
export function categories(items: ResolvedItem[]): Array<{ name: string; count: number }> {
  const map = new Map<string, number>();
  for (const it of items) map.set(it.category, (map.get(it.category) ?? 0) + 1);
  return [...map.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count);
}

/** 이번 달 리포트 — intent 별 저장 수 */
export function monthlyReport(items: ResolvedItem[], now: number) {
  const p = kstParts(now);
  const monthItems = items.filter((i) => {
    const c = kstParts(i.capturedAt);
    return c.year === p.year && c.month === p.month;
  });
  const byIntent = { schedule: 0, todo: 0, knowledge: 0, memo: 0 } as Record<IntentType, number>;
  for (const it of monthItems) byIntent[it.primaryIntent] += 1;
  return { total: monthItems.length, byIntent };
}

/* ── 표시 포맷 ─────────────────────────────── */

export function relativeLabel(ts: number, now: number): string {
  const diff = now - ts;
  if (diff < 3_600_000) return "방금 전";
  if (diff < DAY) return `${Math.floor(diff / 3_600_000)}시간 전`;
  const days = Math.floor((midnight(now) - midnight(ts)) / DAY);
  if (days === 1) return "어제";
  if (days < 7) return `${days}일 전`;
  if (days < 30) return `${Math.floor(days / 7)}주 전`;
  return `${Math.floor(days / 30)}달 전`;
}

const WEEKDAYS = ["일", "월", "화", "수", "목", "금", "토"];

export function koreanDate(ts: number, withWeekday = true): string {
  const p = kstParts(ts);
  const base = `${p.month}월 ${p.day}일`;
  return withWeekday ? `${base} (${WEEKDAYS[p.weekday]})` : base;
}

export function dday(ts: number, now: number): string {
  const days = Math.round((midnight(ts) - midnight(now)) / DAY);
  if (days === 0) return "오늘";
  if (days === 1) return "내일";
  return days > 0 ? `D-${days}` : `${-days}일 지남`;
}
