import { describe, expect, it } from "vitest";
import { trimStreamingTail } from "./ChatMarkup";

/* 스트리밍 꼬리 정리 — iOS ChatMarkup.trimStreamingTail 과 같은 정책 */

describe("trimStreamingTail", () => {
  it("닫히지 않은 전각 마커 꼬리를 자른다", () => {
    expect(trimStreamingTail("참고하세요 【item:ddade28b-2982-4b")).toBe("참고하세요 ");
    expect(trimStreamingTail("참고하세요 【")).toBe("참고하세요 ");
  });

  it("완성된 전각 마커는 남긴다", () => {
    const done = "참고하세요 【item:ddade28b-2982-4b2c-9311-6ee02e0e134b】.";
    expect(trimStreamingTail(done)).toBe(done);
  });

  it("반각은 [item: 프리픽스가 보일 때만 자른다 — 폴백 [n] 배지는 보존", () => {
    expect(trimStreamingTail("근거는 [item:5581683b-c6")).toBe("근거는 ");
    expect(trimStreamingTail("근거는 [1] 입니다")).toBe("근거는 [1] 입니다");
  });

  it("짝이 안 맞는 마지막 ** 이후를 자른다", () => {
    expect(trimStreamingTail("정리하면 **핵심")).toBe("정리하면 ");
    expect(trimStreamingTail("정리하면 **핵심** 입니다")).toBe("정리하면 **핵심** 입니다");
  });
});
