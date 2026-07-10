"use client";

import { Component, Suspense, useCallback, useMemo, useRef, type ReactNode } from "react";
import { Canvas, useFrame, useThree } from "@react-three/fiber";
import { Image as DreiImage, useTexture } from "@react-three/drei";
import * as THREE from "three";
import { roundedRectShape } from "@/lib/roundedRectShape";

/*
 * S0 랜딩 — 기억 파편 필드.
 * 실제 캡처 텍스처 14장이 라벤더 공간에 부유하다가, CTA 에 손이 닿으면
 * 화면 중앙(카피) 둘레의 고리로 모여든다 — "필요한 기억은 쉽게 떠오른다"의 시각화.
 *
 * 렌더링은 전부 unlit — 조명·fog·톤매핑을 쓰면 백킹 프레임만 물들고
 * drei Image 셰이더(fog 미지원)는 안 물들어 회색 테두리처럼 어긋난다.
 * 깊이감은 대신 프레임·이미지에 "동일하게" 곱해지는 깊이 tint 로 낸다.
 */

interface Slot {
  /** 화면비 1.6 기준 NDC(-1~1) — 월드좌표는 aspect 에 맞춰 런타임 계산 */
  nx: number;
  ny: number;
  z: number;
  rotZ: number;
  scale: number;
  speed: number;
  phase: number;
}

/*
 * 슬롯은 스크린 공간(NDC)에서 설계한다 — 투영 계산으로 두 가지를 보장:
 * (1) 중앙 카피 블록(x ±0.62, y -0.40~+0.50 + 카드 반폭 여유) 불침범,
 * (2) 카드 상단(top+bob) ≤ 0.87 — 헤더(로고·바로체험, y>0.885)는 px 고정이라
 *     해상도마다 NDC 위치가 흘러 다녀서 y 상한으로만 전 해상도 분리가 된다.
 * 좌우 각 7장: 근경 앵커 2 + 가장자리 반절림 1 + 원경 상단 1 + 원경 중단 1
 * + 하단 1 + 상단 중앙(x 중앙은 헤더가 비어 x 제약 없음) 1.
 */
const SLOTS: Slot[] = [
  { nx: -0.80, ny: 0.52, z: -0.7, rotZ: 0.05, scale: 0.94, speed: 0.42, phase: 0.0 },
  { nx: -0.94, ny: -0.05, z: -1.6, rotZ: -0.04, scale: 0.88, speed: 0.55, phase: 1.4 },
  { nx: -0.82, ny: -0.62, z: -0.9, rotZ: -0.05, scale: 0.9, speed: 0.48, phase: 4.1 },
  { nx: -0.60, ny: 0.66, z: -2.6, rotZ: 0.07, scale: 0.8, speed: 0.36, phase: 2.9 },
  { nx: -0.70, ny: -0.20, z: -2.9, rotZ: 0.04, scale: 0.78, speed: 0.6, phase: 5.3 },
  { nx: -0.42, ny: -0.86, z: -2.2, rotZ: -0.03, scale: 0.8, speed: 0.4, phase: 0.8 },
  { nx: -0.16, ny: 0.82, z: -3.4, rotZ: -0.05, scale: 0.72, speed: 0.37, phase: 2.6 },
  { nx: 0.78, ny: 0.55, z: -0.8, rotZ: -0.05, scale: 0.92, speed: 0.44, phase: 2.2 },
  { nx: 0.95, ny: -0.02, z: -1.5, rotZ: 0.04, scale: 0.86, speed: 0.52, phase: 3.6 },
  { nx: 0.80, ny: -0.64, z: -0.8, rotZ: 0.06, scale: 0.92, speed: 0.46, phase: 0.4 },
  { nx: 0.58, ny: 0.66, z: -2.7, rotZ: -0.07, scale: 0.78, speed: 0.38, phase: 4.8 },
  { nx: 0.70, ny: -0.22, z: -3.0, rotZ: -0.04, scale: 0.76, speed: 0.58, phase: 1.9 },
  { nx: 0.45, ny: -0.88, z: -2.4, rotZ: 0.03, scale: 0.78, speed: 0.41, phase: 3.1 },
  { nx: 0.18, ny: 0.84, z: -3.5, rotZ: 0.05, scale: 0.72, speed: 0.34, phase: 5.9 },
];

/** 캡처 텍스처 — 슬롯 순서대로. 어두운 캡처·컬러 캡처가 한쪽에 몰리지 않게 배열 */
const FRAGMENT_IMAGES = [
  "/seed/caps/yuna-cafe-window.jpg",
  "/seed/caps/sena-lms-os.jpg",
  "/seed/caps/dohyun-slack.jpg",
  "/seed/caps/yuna-flower.jpg",
  "/seed/caps/dohyun-ddia.jpg",
  "/seed/caps/sena-youtube-langchain.jpg",
  "/seed/caps/yuna-exhibition.jpg",
  "/seed/caps/sena-ticketing.jpg",
  "/seed/caps/dohyun-kakao.jpg",
  "/seed/caps/yuna-popup.jpg",
  "/seed/caps/yuna-dress.jpg",
  "/seed/caps/sena-contest.jpg",
  "/seed/caps/yuna-cafe-brunch.jpg",
  "/seed/caps/dohyun-k8s.jpg",
];

const CARD_W = 0.92;
const CARD_H = 1.9;
// 앞면(DreiImage radius 0.05)과 평행 곡선이 되도록 — 백킹 여백 0.04 만큼 반경도 키운다
const FRAG_R = 0.05;
const FRAG_M = 0.04;
const FRAG_DEPTH = 0.04;
const FRAG_SHAPE = roundedRectShape(CARD_W + FRAG_M * 2, CARD_H + FRAG_M * 2, FRAG_R + FRAG_M);

const CAM_Z = 8;
const HALF_V = Math.tan((42 * Math.PI) / 360); // 수직 half-fov tangent
/** aspect 1.45 미만으로 좁아져도 카드를 카피 쪽으로 밀어넣지 않는다 — 대신 화면 밖으로 잘린다 */
const MIN_ASPECT = 1.45;
// 수렴 고리(z=-0.9) — 중앙 카피를 덮지 않는 타원, NDC 로 정의해 화면비 추종
const RING_NX = 0.8;
const RING_NY = 0.72;
const RING_Z = -0.9;
const RING_SCALE = 0.6;

/** NDC → 월드 — z 깊이의 프러스텀 단면 크기로 환산 */
function ndcToWorld(nx: number, ny: number, z: number, aspect: number) {
  const halfH = HALF_V * (CAM_Z - z);
  return { x: nx * halfH * Math.max(aspect, MIN_ASPECT), y: ny * halfH };
}

/**
 * 타원 위 n 점을 호 길이 균등으로 분배 — 등각 분배는 타원 좌우 측면에서
 * 점이 수직으로 뭉쳐 카드 두 장이 한 장처럼 붙는다. 위쪽(π/2)부터 시작.
 */
function ringTargets(n: number, rx: number, ry: number) {
  const STEPS = 720;
  const xs: number[] = [];
  const ys: number[] = [];
  const cum: number[] = [0];
  for (let i = 0; i <= STEPS; i++) {
    const a = Math.PI / 2 + (i / STEPS) * Math.PI * 2;
    xs.push(Math.cos(a) * rx);
    ys.push(Math.sin(a) * ry);
    if (i > 0) cum.push(cum[i - 1] + Math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]));
  }
  const total = cum[STEPS];
  const pts: { x: number; y: number }[] = [];
  let j = 0;
  for (let i = 0; i < n; i++) {
    const target = (i / n) * total;
    while (cum[j + 1] < target) j++;
    const t = (target - cum[j]) / (cum[j + 1] - cum[j]);
    pts.push({ x: THREE.MathUtils.lerp(xs[j], xs[j + 1], t), y: THREE.MathUtils.lerp(ys[j], ys[j + 1], t) });
  }
  return pts;
}

/** 원경일수록 라벤더 공간에 잠기는 깊이 tint — 프레임·이미지에 동일 적용 */
function depthTint(z: number) {
  const k = THREE.MathUtils.clamp((-z - 1.2) / 3.0, 0, 1) * 0.4;
  return new THREE.Color("#ffffff").lerp(new THREE.Color("#c9bfe8"), k);
}

function FragmentCard({
  slot,
  texture,
  ring,
  aspect,
  gatherRef,
}: {
  slot: Slot;
  texture: THREE.Texture;
  ring: { x: number; y: number };
  aspect: number;
  gatherRef: React.RefObject<number>;
}) {
  const group = useRef<THREE.Group>(null);

  const { pos, tint } = useMemo(
    () => ({ pos: ndcToWorld(slot.nx, slot.ny, slot.z, aspect), tint: depthTint(slot.z) }),
    [slot, aspect],
  );

  useFrame((state) => {
    const g = group.current;
    if (!g) return;
    const t = state.clock.elapsedTime;
    const k = gatherRef.current ?? 0;
    const bob = Math.sin(t * slot.speed + slot.phase) * 0.12;
    const bobX = Math.cos(t * slot.speed * 0.7 + slot.phase) * 0.05;
    g.position.set(
      THREE.MathUtils.lerp(pos.x + bobX, ring.x, k),
      THREE.MathUtils.lerp(pos.y + bob, ring.y + bob * 0.4, k),
      THREE.MathUtils.lerp(slot.z, RING_Z, k),
    );
    // 부유 중엔 중앙을 살짝 바라보고, 모이면 정면
    g.rotation.set(
      0,
      THREE.MathUtils.lerp(-pos.x * 0.05, 0, k),
      THREE.MathUtils.lerp(slot.rotZ + Math.sin(t * slot.speed * 0.5 + slot.phase) * 0.02, 0, k),
    );
    const s = THREE.MathUtils.lerp(slot.scale, RING_SCALE, k);
    g.scale.setScalar(s);
  });

  return (
    <group ref={group}>
      <mesh position={[0, 0, -FRAG_DEPTH / 2]}>
        <extrudeGeometry
          args={[FRAG_SHAPE, { depth: FRAG_DEPTH, bevelEnabled: false, curveSegments: 16 }]}
        />
        <meshBasicMaterial color={tint} toneMapped={false} />
      </mesh>
      <DreiImage
        texture={texture}
        scale={[CARD_W, CARD_H]}
        position={[0, 0, 0.026]}
        radius={FRAG_R}
        color={tint}
        transparent
        toneMapped={false}
      />
    </group>
  );
}

interface FieldProps {
  /** 수렴 목표 0|1 — 프레임 루프가 스프링처럼 따라간다 */
  gatherTargetRef: React.RefObject<number>;
  /** 정규화 포인터(-1~1) — canvas 는 pointer-events:none 이라 window 에서 수집 */
  pointerRef: React.RefObject<{ x: number; y: number }>;
  /** 히어로가 화면 밖일 때 프레임 루프 정지 */
  paused?: boolean;
}

/** 텍스처 로딩 실패가 Canvas 전체를 깨지 않게 — 파편은 장식이라 조용히 생략 */
class FragmentBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? null : this.props.children;
  }
}

function Fragments({ gatherRef }: { gatherRef: React.RefObject<number> }) {
  const gl = useThree((s) => s.gl);
  const aspect = useThree((s) => s.viewport.aspect);

  // sRGB 지정(미지정 시 물빠진 색) + anisotropy(기울어진 카드의 텍스처 계단 방지)
  const configure = useCallback(
    (loaded: THREE.Texture | THREE.Texture[]) => {
      const aniso = Math.min(8, gl.capabilities.getMaxAnisotropy());
      for (const t of Array.isArray(loaded) ? loaded : [loaded]) {
        t.colorSpace = THREE.SRGBColorSpace;
        t.anisotropy = aniso;
        t.needsUpdate = true;
      }
    },
    [gl],
  );
  const textures = useTexture(FRAGMENT_IMAGES, configure);

  const rings = useMemo(() => {
    const halfH = HALF_V * (CAM_Z - RING_Z);
    return ringTargets(SLOTS.length, RING_NX * halfH * Math.max(aspect, MIN_ASPECT), RING_NY * halfH);
  }, [aspect]);

  return (
    <>
      {SLOTS.map((slot, i) => (
        <FragmentCard
          key={i}
          slot={slot}
          texture={textures[i % textures.length]}
          ring={rings[i]}
          aspect={aspect}
          gatherRef={gatherRef}
        />
      ))}
    </>
  );
}

function FieldScene({ gatherTargetRef, pointerRef }: Omit<FieldProps, "paused">) {
  const rig = useRef<THREE.Group>(null);
  const gather = useRef(0);

  useFrame((_, dt) => {
    const g = rig.current;
    const p = pointerRef.current;
    if (!g || !p) return;
    const k = 1 - Math.exp(-Math.min(dt, 0.05) * 4);
    g.rotation.y += (p.x * 0.05 - g.rotation.y) * k;
    g.rotation.x += (-p.y * 0.035 - g.rotation.x) * k;
    const kg = 1 - Math.exp(-Math.min(dt, 0.05) * 3.4);
    gather.current += ((gatherTargetRef.current ?? 0) - gather.current) * kg;
  });

  return (
    <FragmentBoundary>
      <Suspense fallback={null}>
        <group ref={rig}>
          <Fragments gatherRef={gather} />
        </group>
      </Suspense>
    </FragmentBoundary>
  );
}

export default function LandingCanvas({ paused, ...props }: FieldProps) {
  return (
    <Canvas
      flat
      gl={{ alpha: true, antialias: true }}
      dpr={[1, 2]}
      camera={{ fov: 42, position: [0, 0, CAM_Z] }}
      frameloop={paused ? "never" : "always"}
      style={{ position: "absolute", inset: 0, pointerEvents: "none" }}
      aria-hidden
    >
      <FieldScene {...props} />
    </Canvas>
  );
}
