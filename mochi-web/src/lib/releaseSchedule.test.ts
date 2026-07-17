import { describe, expect, it } from "vitest";
import { isCodeRepositoryVisible } from "./releaseSchedule";

describe("isCodeRepositoryVisible", () => {
  it("2026년 7월 20일 0시 KST 전에는 코드를 숨긴다", () => {
    expect(isCodeRepositoryVisible(Date.parse("2026-07-19T23:59:59+09:00"))).toBe(false);
  });

  it("2026년 7월 20일 0시 KST부터 코드를 보여준다", () => {
    expect(isCodeRepositoryVisible(Date.parse("2026-07-20T00:00:00+09:00"))).toBe(true);
  });
});
