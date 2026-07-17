import type { AnalyzedItemWire, PlaceWire } from "@/lib/api/wire";
import type { CaptureThumb } from "@/lib/captureImage";
import type { SeedRecallEntry } from "@seed/schema";
import {
  pickPrimaryIntent,
  type ResolvedInstance,
  type ResolvedItem,
} from "@/lib/seedRuntime";

/*
 * 세션 로컬 오버레이 — 이 브라우저에서 라이브로 보낸 기록을 시드 위에 합성한다.
 * 시드는 불변(PersonaProvider 규약), 오버레이는 sessionStorage 에만 산다:
 * 페르소나 백엔드 계정은 모든 심사위원이 공유하므로, 화면에는 "내가 보낸 것"만 얹는다.
 */

export interface LiveCaptureEntry {
  /** 시드와 충돌하지 않는 오버레이 전용 slug (`live-` prefix) */
  slug: string;
  capturedAt: number;
  kind: "screenshot" | "url" | "memo";
  wire: AnalyzedItemWire;
  text?: string;
  url?: string;
  memo?: string;
  thumb?: CaptureThumb;
  /** 예시 카드의 사람이 읽는 제목. 분석 결과를 덮지 않고 회수 추천에만 보탠다. */
  retrievalHint?: string;
}

const storageKey = (personaSlug: string) => `mochi-live-captures-${personaSlug}`;
const MAX_ENTRIES = 12;
const EMPTY: LiveCaptureEntry[] = [];

/** wire id(uuid 또는 fb.base64url)를 slug 규격으로 — 같은 id 는 항상 같은 slug (자연 dedup) */
export function liveSlugFor(wireId: string): string {
  let h = 5381;
  for (let i = 0; i < wireId.length; i++) h = ((h << 5) + h + wireId.charCodeAt(i)) >>> 0;
  return `live-${h.toString(36)}`;
}

export function loadLiveCaptures(personaSlug: string): LiveCaptureEntry[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = sessionStorage.getItem(storageKey(personaSlug));
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (e): e is LiveCaptureEntry =>
        !!e &&
        typeof e === "object" &&
        typeof (e as LiveCaptureEntry).slug === "string" &&
        typeof (e as LiveCaptureEntry).capturedAt === "number" &&
        !!(e as LiveCaptureEntry).wire &&
        Array.isArray((e as LiveCaptureEntry).wire.intents),
    );
  } catch {
    return [];
  }
}

function persist(personaSlug: string, entries: LiveCaptureEntry[]): void {
  if (typeof window === "undefined") return;
  try {
    sessionStorage.setItem(
      storageKey(personaSlug),
      JSON.stringify(entries.slice(0, MAX_ENTRIES)),
    );
  } catch {
    // 쿼터 초과 — 썸네일을 떼고 한 번 더 시도
    try {
      sessionStorage.setItem(
        storageKey(personaSlug),
        JSON.stringify(
          entries.slice(0, MAX_ENTRIES).map((e) => {
            const copy = { ...e };
            delete copy.thumb;
            return copy;
          }),
        ),
      );
    } catch {
      /* 그래도 실패면 이 탭의 메모리 상태로만 산다 */
    }
  }
}

/* ── 외부 스토어 (useSyncExternalStore 계약) ──
 * SSR/하이드레이션 스냅숏은 항상 빈 배열 — 마운트 후 sessionStorage 스냅숏으로 교체된다. */

const cache = new Map<string, LiveCaptureEntry[]>();
const listeners = new Map<string, Set<() => void>>();

export function subscribeLiveCaptures(
  personaSlug: string,
  onChange: () => void,
): () => void {
  const set = listeners.get(personaSlug) ?? new Set();
  set.add(onChange);
  listeners.set(personaSlug, set);
  return () => {
    set.delete(onChange);
  };
}

export function getLiveCaptures(personaSlug: string): LiveCaptureEntry[] {
  if (typeof window === "undefined") return EMPTY;
  let cur = cache.get(personaSlug);
  if (!cur) {
    cur = loadLiveCaptures(personaSlug);
    cache.set(personaSlug, cur);
  }
  return cur;
}

export function getServerLiveCaptures(): LiveCaptureEntry[] {
  return EMPTY;
}

/** 최신 우선 upsert — 같은 slug(같은 wire id) 재전송은 갱신 */
export function addLiveCapture(personaSlug: string, entry: LiveCaptureEntry): void {
  const next = [
    entry,
    ...getLiveCaptures(personaSlug).filter((e) => e.slug !== entry.slug),
  ].slice(0, MAX_ENTRIES);
  cache.set(personaSlug, next);
  persist(personaSlug, next);
  listeners.get(personaSlug)?.forEach((fn) => fn());
}

/** 새 데모 방문자 시작 — 이전 방문자의 탭 로컬 기록과 메모리 캐시를 함께 비운다. */
export function clearAllLiveCaptures(): void {
  if (typeof window === "undefined") return;
  const affected = new Set([...cache.keys(), ...listeners.keys()]);
  for (let i = sessionStorage.length - 1; i >= 0; i--) {
    const key = sessionStorage.key(i);
    if (!key?.startsWith("mochi-live-captures-")) continue;
    affected.add(key.slice("mochi-live-captures-".length));
    sessionStorage.removeItem(key);
  }
  affected.forEach((personaSlug) => {
    cache.set(personaSlug, EMPTY);
    listeners.get(personaSlug)?.forEach((fn) => fn());
  });
}

export interface LiveCaptureInput {
  kind: LiveCaptureEntry["kind"];
  text?: string;
  url?: string;
  memo?: string;
  thumb?: CaptureThumb;
  retrievalHint?: string;
  /** 예시 레일의 검증된 장소 메타 — 분석 폴백에서도 지도 상세를 보존한다. */
  place?: PlaceWire;
}

export function makeLiveEntry(
  wire: AnalyzedItemWire,
  input: LiveCaptureInput,
): LiveCaptureEntry {
  return {
    slug: liveSlugFor(wire.id),
    capturedAt: Date.now(),
    kind: input.kind,
    wire: input.place && !wire.place ? { ...wire, place: input.place } : wire,
    // BFF 수용 상한과 동일 — sessionStorage 도 무한정 커지지 않게
    text: input.text?.slice(0, 2000),
    url: input.url,
    memo: input.memo?.slice(0, 500),
    thumb: input.thumb,
    retrievalHint: input.retrievalHint?.slice(0, 120),
  };
}

/** 분석 결과의 날짜 문자열은 형식 보장이 없다 — YYYY-MM-DD 접두만 신뢰 (NaN 방지) */
export function parseKstDate(value?: string): number | undefined {
  const m = value ? /^\d{4}-\d{2}-\d{2}/.exec(value.trim()) : null;
  if (!m) return undefined;
  const t = Date.parse(`${m[0]}T00:00:00+09:00`);
  return Number.isFinite(t) ? t : undefined;
}

const SOURCE_LABEL: Record<LiveCaptureEntry["kind"], string> = {
  screenshot: "스크린샷",
  url: "링크",
  memo: "직접 입력",
};

/** 오버레이 항목 → 시드와 같은 ResolvedItem — 홈·검색·상세가 구분 없이 렌더한다 */
export function resolveLiveCapture(entry: LiveCaptureEntry): ResolvedItem {
  const intents = entry.wire.intents.length
    ? entry.wire.intents
    : [{ intentType: "memo" as const, label: entry.wire.title }];

  const instances: ResolvedInstance[] = intents.map((intent) => ({
    intentType: intent.intentType,
    label: intent.label,
    done: false,
    payload: {
      title: intent.label,
      time: intent.time,
    },
    dueAt: parseKstDate(intent.date ?? intent.deadline),
  }));

  return {
    slug: entry.slug,
    kind: entry.kind,
    channel: entry.kind === "screenshot" ? "screenshot" : "appDirectInput",
    source: SOURCE_LABEL[entry.kind],
    title: entry.wire.title,
    url: entry.url ?? entry.wire.url,
    text: entry.text ?? entry.wire.text,
    userMemo: entry.memo ?? entry.wire.userMemo,
    category: entry.wire.category,
    summary: entry.wire.summary,
    shoppingProductQuery: entry.wire.shoppingProductQuery,
    referenceLinks: entry.wire.referenceLinks,
    place: entry.wire.place,
    // 스킴 가드 — sessionStorage 값이 어떤 경로로 오염돼도 이미지 data URL 만 렌더에 올린다
    image:
      entry.thumb && entry.thumb.dataUrl.startsWith("data:image/")
        ? {
            file: entry.thumb.dataUrl,
            width: entry.thumb.width,
            height: entry.thumb.height,
          }
        : undefined,
    capturedAt: entry.capturedAt,
    instances,
    primaryIntent: pickPrimaryIntent(instances),
    retrievalHint: entry.retrievalHint,
  };
}

export function resolveLiveCaptures(entries: LiveCaptureEntry[]): ResolvedItem[] {
  return entries.map(resolveLiveCapture);
}

/** 현재 브라우저 세션에서 보낸 기록만 리마인드 덱에 합성한다. */
export function liveRecallEntries(items: ResolvedItem[]): SeedRecallEntry[] {
  return items.map((item) => {
    const labels = [...new Set(item.instances.map((instance) => instance.label).filter(Boolean))];
    return {
      itemSlug: item.slug,
      kind: "linkedToRecent",
      oneline: `‘${item.title}’, 다시 가져왔어요`,
      gist: [item.summary, labels.join(" · ")].filter(Boolean).slice(0, 2),
    };
  });
}
