"use client";

 
import { Component, Suspense, useRef, type ReactNode } from "react";
import { Canvas, useFrame } from "@react-three/fiber";
import { Image as DreiImage, RoundedBox } from "@react-three/drei";
import * as THREE from "three";

/*
 * S0 랜딩 — 기억 파편 필드.
 * 실제 캡처 텍스처 14장이 라벤더 공간에 부유하다가, CTA 에 손이 닿으면
 * 화면 중앙(카피) 둘레의 고리로 모여든다 — "필요한 기억은 쉽게 떠오른다"의 시각화.
 * 조명은 라이트 3개 고정 (Environment preset 은 CDN 페치라 오프라인 데모 금지).
 */

interface Slot {
  x: number;
  y: number;
  z: number;
  rotZ: number;
  scale: number;
  speed: number;
  phase: number;
}

/** 손배치 슬롯 — 중앙 카피 영역을 비우고 좌우·깊이로 분산 */
const SLOTS: Slot[] = [
  { x: -4.7, y: 1.5, z: -1.8, rotZ: 0.05, scale: 1.0, speed: 0.42, phase: 0.0 },
  { x: -3.4, y: -0.7, z: -0.6, rotZ: -0.04, scale: 0.9, speed: 0.55, phase: 1.4 },
  { x: -2.6, y: 1.9, z: -2.6, rotZ: 0.07, scale: 0.82, speed: 0.36, phase: 2.9 },
  { x: -5.0, y: -1.7, z: -2.2, rotZ: -0.06, scale: 0.95, speed: 0.48, phase: 4.1 },
  { x: -2.1, y: -2.0, z: -1.2, rotZ: 0.04, scale: 0.78, speed: 0.6, phase: 5.3 },
  { x: -4.0, y: 0.3, z: 0.2, rotZ: -0.03, scale: 1.06, speed: 0.4, phase: 0.8 },
  { x: 4.7, y: 1.4, z: -1.9, rotZ: -0.05, scale: 1.0, speed: 0.44, phase: 2.2 },
  { x: 3.5, y: -0.8, z: -0.5, rotZ: 0.04, scale: 0.9, speed: 0.52, phase: 3.6 },
  { x: 2.6, y: 2.0, z: -2.7, rotZ: -0.07, scale: 0.8, speed: 0.38, phase: 4.8 },
  { x: 5.0, y: -1.6, z: -2.3, rotZ: 0.06, scale: 0.96, speed: 0.46, phase: 0.4 },
  { x: 2.2, y: -2.1, z: -1.3, rotZ: -0.04, scale: 0.76, speed: 0.58, phase: 1.9 },
  { x: 4.0, y: 0.5, z: 0.1, rotZ: 0.03, scale: 1.04, speed: 0.41, phase: 3.1 },
  { x: 0.4, y: 2.8, z: -3.4, rotZ: 0.05, scale: 0.85, speed: 0.34, phase: 5.9 },
  { x: -0.6, y: -3.0, z: -3.2, rotZ: -0.05, scale: 0.85, speed: 0.37, phase: 2.6 },
];

/** 캡처 텍스처 — 세 페르소나의 실제 시드 이미지를 골고루 */
const FRAGMENT_IMAGES = [
  "/seed/caps/yuna-cafe-window.jpg",
  "/seed/caps/sena-lms-os.jpg",
  "/seed/caps/dohyun-k8s.jpg",
  "/seed/caps/yuna-flower.jpg",
  "/seed/caps/sena-youtube-langchain.jpg",
  "/seed/caps/dohyun-slack.jpg",
  "/seed/caps/yuna-exhibition.jpg",
  "/seed/caps/sena-ticketing.jpg",
  "/seed/caps/dohyun-ddia.jpg",
  "/seed/caps/yuna-popup.jpg",
  "/seed/caps/sena-contest.jpg",
  "/seed/caps/dohyun-kakao.jpg",
  "/seed/caps/yuna-cafe-brunch.jpg",
  "/seed/caps/yuna-dress.jpg",
];

const CARD_W = 0.92;
const CARD_H = 1.9;
// 수렴 고리 — 중앙 카피(헤드라인 반폭 ~2.6u)를 덮지 않는 타원
const RING_X = 4.5;
const RING_Y = 2.35;
const RING_SCALE = 0.6;

function FragmentCard({
  slot,
  url,
  index,
  gatherRef,
}: {
  slot: Slot;
  url: string;
  index: number;
  gatherRef: React.RefObject<number>;
}) {
  const group = useRef<THREE.Group>(null);

  // 고리 위 목표점 — index 균등 분배, 위쪽부터
  const angle = (index / SLOTS.length) * Math.PI * 2 + Math.PI / 2;
  const ring = {
    x: Math.cos(angle) * RING_X,
    y: Math.sin(angle) * RING_Y,
    z: -0.9,
  };

  useFrame((state) => {
    const g = group.current;
    if (!g) return;
    const t = state.clock.elapsedTime;
    const k = gatherRef.current ?? 0;
    const bob = Math.sin(t * slot.speed + slot.phase) * 0.12;
    const bobX = Math.cos(t * slot.speed * 0.7 + slot.phase) * 0.05;
    g.position.set(
      THREE.MathUtils.lerp(slot.x + bobX, ring.x, k),
      THREE.MathUtils.lerp(slot.y + bob, ring.y + bob * 0.4, k),
      THREE.MathUtils.lerp(slot.z, ring.z, k),
    );
    // 부유 중엔 중앙을 살짝 바라보고, 모이면 정면
    g.rotation.set(
      0,
      THREE.MathUtils.lerp(-slot.x * 0.05, 0, k),
      THREE.MathUtils.lerp(slot.rotZ + Math.sin(t * slot.speed * 0.5 + slot.phase) * 0.02, 0, k),
    );
    const s = THREE.MathUtils.lerp(slot.scale, RING_SCALE, k);
    g.scale.setScalar(s);
  });

  return (
    <group ref={group}>
      <RoundedBox args={[CARD_W + 0.08, CARD_H + 0.08, 0.04]} radius={0.045} smoothness={2}>
        <meshStandardMaterial color="#ffffff" roughness={0.4} metalness={0.04} />
      </RoundedBox>
      <DreiImage
        url={url}
        scale={[CARD_W, CARD_H]}
        position={[0, 0, 0.026]}
        radius={0.05}
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
    <>
      <fog attach="fog" args={["#e3def5", 7.5, 15]} />
      <ambientLight intensity={1.05} />
      <directionalLight position={[4, 6, 6]} intensity={1.1} />
      <directionalLight position={[-6, -3, 4]} intensity={0.4} color="#B49AFF" />
      <FragmentBoundary>
        <Suspense fallback={null}>
          <group ref={rig}>
            {SLOTS.map((slot, i) => (
              <FragmentCard
                key={i}
                slot={slot}
                url={FRAGMENT_IMAGES[i % FRAGMENT_IMAGES.length]}
                index={i}
                gatherRef={gather}
              />
            ))}
          </group>
        </Suspense>
      </FragmentBoundary>
    </>
  );
}

export default function LandingCanvas({ paused, ...props }: FieldProps) {
  return (
    <Canvas
      gl={{ alpha: true, antialias: true }}
      dpr={[1, 1.5]}
      camera={{ fov: 42, position: [0, 0, 8] }}
      frameloop={paused ? "never" : "always"}
      style={{ position: "absolute", inset: 0, pointerEvents: "none" }}
      aria-hidden
    >
      <FieldScene {...props} />
    </Canvas>
  );
}
