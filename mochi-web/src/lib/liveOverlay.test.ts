import { describe, expect, it } from "vitest";
import type { AnalyzedItemWire } from "@/lib/api/wire";
import {
  liveSlugFor,
  liveRecallEntries,
  makeLiveEntry,
  parseKstDate,
  resolveLiveCapture,
} from "./liveOverlay";

/* 세션 오버레이 — wire → ResolvedItem 변환이 시드 렌더 규약과 맞는지 */

const wire: AnalyzedItemWire = {
  id: "3f2a9b1c-0000-4000-8000-000000000001",
  title: "금요일 팀 미팅 준비",
  summary: "일정으로 정리했어요.",
  category: "회사",
  intents: [
    { intentType: "schedule", label: "팀 미팅", date: "2026-07-17", time: "15:00" },
    { intentType: "todo", label: "발표자료 만들기", deadline: "2026-07-16" },
  ],
};

describe("liveSlugFor", () => {
  it("같은 wire id 는 항상 같은 slug (자연 dedup) — slug 규격 준수", () => {
    expect(liveSlugFor(wire.id)).toBe(liveSlugFor(wire.id));
    expect(liveSlugFor(wire.id)).toMatch(/^live-[a-z0-9]+$/);
    expect(liveSlugFor("fb.eyJ0ZXh0IjoibWVtbyJ9")).toMatch(/^live-[a-z0-9]+$/);
  });
});

describe("parseKstDate", () => {
  it("YYYY-MM-DD 접두만 신뢰 — KST 자정", () => {
    const t = parseKstDate("2026-07-17")!;
    expect(new Date(t).toISOString()).toBe("2026-07-16T15:00:00.000Z");
    expect(parseKstDate("2026-07-17T09:00:00")).toBe(t);
  });
  it("형식 밖 입력은 undefined (NaN 칩 방지)", () => {
    expect(parseKstDate(undefined)).toBeUndefined();
    expect(parseKstDate("금요일")).toBeUndefined();
    expect(parseKstDate("2026-99-99")).toBeUndefined();
  });
});

describe("resolveLiveCapture", () => {
  it("intents → instances(dueAt 포함) + 대표 intent 우선순위", () => {
    const entry = makeLiveEntry(wire, {
      kind: "memo",
      text: "원문",
      retrievalHint: "팀 회의 예시",
    });
    const item = resolveLiveCapture(entry);
    expect(item.slug).toBe(liveSlugFor(wire.id));
    expect(item.primaryIntent).toBe("schedule");
    expect(item.instances).toHaveLength(2);
    expect(item.instances[0].dueAt).toBe(parseKstDate("2026-07-17"));
    expect(item.instances[0].payload?.time).toBe("15:00");
    expect(item.instances[1].dueAt).toBe(parseKstDate("2026-07-16"));
    expect(item.text).toBe("원문");
    expect(item.retrievalHint).toBe("팀 회의 예시");
  });

  it("intents 가 비면 memo 1건으로 정직하게 (기록은 반드시 남는다)", () => {
    const entry = makeLiveEntry(
      { ...wire, intents: [] },
      { kind: "url", url: "https://example.com" },
    );
    const item = resolveLiveCapture(entry);
    expect(item.instances).toHaveLength(1);
    expect(item.primaryIntent).toBe("memo");
    expect(item.url).toBe("https://example.com");
  });

  it("스크린샷 썸네일은 타일 이미지가 된다", () => {
    const entry = makeLiveEntry(wire, {
      kind: "screenshot",
      thumb: { dataUrl: "data:image/jpeg;base64,xxxx", width: 400, height: 300 },
    });
    const item = resolveLiveCapture(entry);
    expect(item.kind).toBe("screenshot");
    expect(item.channel).toBe("screenshot");
    expect(item.image).toEqual({
      file: "data:image/jpeg;base64,xxxx",
      width: 400,
      height: 300,
    });
  });

  it("라이브 상세 보강 정보와 원문을 잃지 않는다", () => {
    const entry = makeLiveEntry(
      {
        ...wire,
        url: "https://example.com/original",
        text: "서버가 보존한 원문",
        userMemo: "사용자가 덧붙인 메모",
        shoppingProductQuery: "모찌 키링 보라색",
        referenceLinks: [
          {
            url: "https://example.com/reference",
            title: "모찌 키링 구매처",
            label: "구매하기",
            role: "buy",
            provider: "official",
            rankProfile: "general",
            usefulness: 5,
          },
        ],
        place: {
          name: "모찌 카페",
          lat: 37.5,
          lng: 127,
          roadAddress: "서울시 어딘가 1",
        },
      },
      { kind: "url" },
    );
    const item = resolveLiveCapture(entry);
    expect(item.url).toBe("https://example.com/original");
    expect(item.text).toBe("서버가 보존한 원문");
    expect(item.userMemo).toBe("사용자가 덧붙인 메모");
    expect(item.referenceLinks?.[0].title).toBe("모찌 키링 구매처");
    expect(item.place?.name).toBe("모찌 카페");
  });

  it("장소 예시는 분석 결과에 장소가 없어도 지도 상세를 보존한다", () => {
    const entry = makeLiveEntry(wire, {
      kind: "memo",
      text: "서울숲에서 만나기",
      place: {
        name: "서울숲",
        lat: 37.5444,
        lng: 127.0374,
        mapUrl: "https://map.naver.com/p/search/seoul-forest",
      },
    });
    expect(resolveLiveCapture(entry).place?.name).toBe("서울숲");
  });

  it("전달받은 현재 세션 항목만 리마인드 엔트리로 만든다", () => {
    const first = resolveLiveCapture(makeLiveEntry(wire, { kind: "memo", text: "내 기록" }));
    const second = resolveLiveCapture(
      makeLiveEntry(
        { ...wire, id: "3f2a9b1c-0000-4000-8000-000000000002", title: "두 번째 기록" },
        { kind: "memo", text: "이것도 내 기록" },
      ),
    );
    const entries = liveRecallEntries([first, second]);

    expect(entries.map((entry) => entry.itemSlug)).toEqual([first.slug, second.slug]);
    expect(entries[0].oneline).toContain(first.title);
  });
});
