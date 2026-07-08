/*
 * 회수 코버플로우 배치 수식 — 정본: mochi-ios RecallHeroView.swift (RecallCoverMetrics).
 * iOS 는 평면(maxTilt=0)이지만 웹은 같은 x/scale/opacity 곡선 위에 실제 깊이(z)와 틸트를 얹는다.
 *
 *  dx    = sign * (min(ad,1)*0.72W + max(ad-1,0)*0.24W)
 *  scale = max(0.78, 1 - ad*0.13)
 *  opacity: ad≤1 → 1-0.1ad, 1<ad<2 → 0.9*(2-ad), ad≥2 → 0
 */

export interface CoverflowConfig {
  /** 카드 폭 (월드 단위) */
  cardWidth: number;
  /** 웹 격상 — 이웃 카드 최대 y축 틸트 (rad) */
  maxTilt: number;
  /** 웹 격상 — 거리당 깊이 후퇴 */
  depthStep: number;
}

export const DEFAULT_CONFIG: CoverflowConfig = {
  cardWidth: 1.7,
  maxTilt: 0.5,
  depthStep: 0.85,
};

export interface Placement {
  x: number;
  z: number;
  rotY: number;
  scale: number;
  opacity: number;
  visible: boolean;
}

/** offset = index - rotation (부호 있는 거리) */
export function placement(
  offset: number,
  cfg: CoverflowConfig = DEFAULT_CONFIG,
): Placement {
  const ad = Math.abs(offset);
  const sign = Math.sign(offset);

  const x =
    sign * (Math.min(ad, 1) * 0.72 + Math.max(ad - 1, 0) * 0.24) * cfg.cardWidth;
  const scale = Math.max(0.78, 1 - ad * 0.13);
  const opacity = ad <= 1 ? 1 - 0.1 * ad : Math.max(0, 0.9 * (2 - ad));

  return {
    x,
    z: -ad * cfg.depthStep,
    rotY: -sign * Math.min(ad, 1) * cfg.maxTilt,
    scale,
    opacity,
    visible: ad < 2,
  };
}

/** N개 순환 덱에서 카드 i 의 최단 순환 offset */
export function circularOffset(index: number, rotation: number, count: number): number {
  const raw = (((index - rotation) % count) + count * 1.5) % count;
  return raw - count / 2;
}

/** 관성 예측 스냅 — 놓는 순간 속도로 목표 인덱스 결정 (iOS predictedEnd 등가) */
export function snapTarget(rotation: number, velocity: number): number {
  return Math.round(rotation + velocity * 0.18);
}
