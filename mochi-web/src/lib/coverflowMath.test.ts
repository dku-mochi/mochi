import { describe, expect, it } from "vitest";
import { placement, circularOffset, DEFAULT_CONFIG } from "./coverflowMath";

/* iOS RecallCoverMetrics 대조표 — cardWidth=W 기준 기대값 */
const W = DEFAULT_CONFIG.cardWidth;

describe("placement (iOS 수식 대조)", () => {
  it("ad=0 — 초점 카드", () => {
    const p = placement(0);
    expect(p.x).toBe(0);
    expect(p.scale).toBe(1);
    expect(p.opacity).toBe(1);
    expect(p.rotY).toBeCloseTo(0, 10);
    expect(p.visible).toBe(true);
  });

  it("ad=0.5 — 드래그 중간", () => {
    const p = placement(0.5);
    expect(p.x).toBeCloseTo(0.36 * W, 5);
    expect(p.scale).toBeCloseTo(0.935, 5);
    expect(p.opacity).toBeCloseTo(0.95, 5);
  });

  it("ad=1 — 첫 이웃 (firstStep 0.72W)", () => {
    const p = placement(1);
    expect(p.x).toBeCloseTo(0.72 * W, 5);
    expect(p.scale).toBeCloseTo(0.87, 5);
    expect(p.opacity).toBeCloseTo(0.9, 5);
    expect(p.rotY).toBeCloseTo(-DEFAULT_CONFIG.maxTilt, 5);
  });

  it("ad=1.5 — laterStep 0.24W 가산", () => {
    const p = placement(-1.5);
    expect(p.x).toBeCloseTo(-(0.72 + 0.5 * 0.24) * W, 5);
    expect(p.scale).toBeCloseTo(0.805, 5);
    expect(p.opacity).toBeCloseTo(0.45, 5);
    expect(p.rotY).toBeCloseTo(DEFAULT_CONFIG.maxTilt, 5);
  });

  it("ad=2 — 최소 스케일 0.78, 소멸", () => {
    const p = placement(2);
    expect(p.scale).toBeCloseTo(0.78, 5);
    expect(p.opacity).toBe(0);
    expect(p.visible).toBe(false);
  });

  it("scale 하한 0.78 유지 (ad=3)", () => {
    expect(placement(3).scale).toBeCloseTo(0.78, 5);
  });
});

describe("circularOffset — 순환 최단 거리", () => {
  it("5장 덱", () => {
    expect(circularOffset(0, 0, 5)).toBe(0);
    expect(circularOffset(1, 0, 5)).toBe(1);
    expect(circularOffset(4, 0, 5)).toBe(-1); // 4는 왼쪽 이웃
    expect(circularOffset(0, 4, 5)).toBe(1); // rotation 4에서 0은 오른쪽
  });

  it("연속 회전에서도 최단 경로", () => {
    expect(circularOffset(2, 6.5, 5)).toBeCloseTo(0.5, 5);
  });
});
