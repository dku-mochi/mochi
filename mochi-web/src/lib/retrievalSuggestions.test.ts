import { describe, expect, it } from "vitest";
import { PERSONAS } from "@seed/index";
import type { CaptureExample } from "@/lib/captureExamples";
import { captureExamplesFor } from "@/lib/captureExamples";
import type { ResolvedItem } from "@/lib/seedRuntime";
import { retrievalSuggestionsFor } from "@/lib/retrievalSuggestions";

function resolvedExample(example: CaptureExample): ResolvedItem {
  const primaryIntent = example.kind === "url" ? "knowledge" : "memo";
  return {
    slug: example.id,
    kind: example.kind,
    channel: example.kind === "screenshot" ? "screenshot" : "appDirectInput",
    source: "입력 예시",
    title: example.title,
    text: example.kind === "memo" ? example.text : undefined,
    url: example.kind === "url" ? example.url : undefined,
    image: example.kind === "screenshot" ? example.image : undefined,
    category: "기록",
    summary: example.kind === "memo" ? example.text : example.title,
    place: example.place,
    capturedAt: Date.now(),
    instances: [{ intentType: primaryIntent, label: example.title }],
    primaryIntent,
    retrievalHint: example.title,
  };
}

describe("retrievalSuggestionsFor", () => {
  it("정확한 제목 대신 검색은 상위 개념, 질문은 자연스러운 회수 문장으로 나눈다", () => {
    const item: ResolvedItem = {
      slug: "live-team-lunch",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "판교 점심 회식 후보",
      category: "장소·맛집",
      summary: "현대백화점 판교점 식당가에서 6인 룸 예약 가능한 곳을 찾아둔 기록이에요.",
      place: { name: "현대백화점 판교점", lat: 37.3928, lng: 127.112 },
      capturedAt: Date.now(),
      instances: [{ intentType: "memo", label: "팀 점심 회식 후보" }],
      primaryIntent: "memo",
    };

    expect(retrievalSuggestionsFor(item)).toEqual({
      search: { query: "회식 장소", label: "회식 장소" },
      chat: {
        text: "저번에 저장했던 괜찮은 회식 장소들 뭐였지?",
        label: "저번에 저장했던 괜찮은 회식 장소들 뭐였지?",
      },
    });
  });

  it("운영 기록은 제목을 되풀이하지 않고 문제 맥락으로 넓힌다", () => {
    const item: ResolvedItem = {
      slug: "live-incident",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "6월 결제 API OOM 장애 회고",
      text: "메모리 상한과 늦은 알림을 다시 확인하기",
      category: "개발·운영",
      summary: "결제 API 메모리 장애의 원인과 후속 조치를 정리했어요.",
      capturedAt: Date.now(),
      instances: [{ intentType: "knowledge", label: "OOM 장애 회고" }],
      primaryIntent: "knowledge",
    };

    const suggestion = retrievalSuggestionsFor(item);
    expect(suggestion.search.query).toBe("운영 이슈");
    expect(suggestion.chat.text).toContain("원인");
    expect(suggestion.chat.text).not.toContain(item.title);
  });

  it.each(PERSONAS)("$name의 입력 예시 45건 모두 제목 복사 없이 검색·질문 단서를 만든다", (persona) => {
    for (const example of captureExamplesFor(persona)) {
      const item = resolvedExample(example);
      const suggestion = retrievalSuggestionsFor(item);
      expect(suggestion.search.query.trim()).not.toBe("");
      expect(suggestion.search.query).not.toBe(item.title);
      expect(suggestion.search.label).toBe(suggestion.search.query);
      expect(suggestion.chat.text.trim()).not.toBe("");
      expect(suggestion.chat.text).not.toBe(item.title);
      expect(suggestion.chat.text.endsWith("?")).toBe(true);
      expect(suggestion.chat.label).toBe(suggestion.chat.text);
    }
  });
});
