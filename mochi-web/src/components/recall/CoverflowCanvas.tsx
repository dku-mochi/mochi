"use client";

/* eslint-disable react-hooks/immutability -- R3F 프레임 루프는 ref 뮤테이션으로 구동하는 것이 관용 패턴 */
import { Suspense, useCallback, useEffect, useMemo, useRef } from "react";
import { Canvas, useFrame, useThree } from "@react-three/fiber";
import { ContactShadows, Image as DreiImage, useTexture } from "@react-three/drei";
import * as THREE from "three";
import { circularOffset, placement, DEFAULT_CONFIG } from "@/lib/coverflowMath";
import type { ResolvedItem } from "@/lib/seedRuntime";
import { roundedRectShape } from "@/lib/roundedRectShape";
import { makeCardTexture } from "./cardTexture";

/*
 * S6 클라이맥스 — 회수 코버플로우의 R3F 무대.
 * 배치 곡선은 iOS 정본(coverflowMath), 깊이·틸트·그림자·두께는 웹 격상.
 * 회전 상태는 DOM(RecallScene)과 공유하는 deck ref 로 구동 — 드래그·휠·키보드는 DOM 소관.
 */

export interface DeckHandle {
  rotation: number;
  target: number;
  dragging: boolean;
}

/** 캡처 이미지 카드의 앞면 — drei Image 의 url 경로는 colorSpace·anisotropy 를
 *  설정하지 않아 물빠진 색 + 미니피케이션 블러가 생긴다(랜딩 파편 필드와 동일 원인).
 *  useTexture 로 직접 로드해 업로드 전에 지정한다. */
function CoverImageFront({
  file,
  frontRef,
  scale,
  position,
  radius,
}: {
  file: string;
  frontRef: React.RefObject<THREE.Mesh | null>;
  scale: [number, number];
  position: [number, number, number];
  radius: number;
}) {
  const gl = useThree((s) => s.gl);
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
  const texture = useTexture(file, configure);
  return (
    <DreiImage
      ref={frontRef as React.RefObject<never>}
      texture={texture}
      scale={scale}
      position={position}
      radius={radius}
      transparent
      toneMapped={false}
    />
  );
}

const CARD_W = DEFAULT_CONFIG.cardWidth;
const CARD_H = CARD_W / 0.53;
// 앞면 코너 반경 — cardTexture 의 44px/512 와 동일 비율 (이미지·텍스처 카드 통일)
const FRONT_R = (44 / 512) * CARD_W;
// 백킹은 앞면보다 사방 0.012 크다 — 평행 곡선이 되도록 반경도 여백만큼 키운다
const BACK_M = 0.012;
const BACK_DEPTH = 0.035;
const BACK_SHAPE = roundedRectShape(CARD_W + BACK_M * 2, CARD_H + BACK_M * 2, FRONT_R + BACK_M);

function CoverCard({
  item,
  index,
  count,
  deck,
}: {
  item: ResolvedItem;
  index: number;
  count: number;
  deck: React.RefObject<DeckHandle>;
}) {
  const group = useRef<THREE.Group>(null);
  const backingMat = useRef<THREE.MeshStandardMaterial>(null);
  const frontRef = useRef<THREE.Mesh>(null);

  const canvasTexture = useMemo(
    () => (item.image ? null : makeCardTexture(item)),
    [item],
  );
  useEffect(() => () => canvasTexture?.dispose(), [canvasTexture]);

  useFrame(() => {
    const g = group.current;
    if (!g || !deck.current) return;
    const p = placement(circularOffset(index, deck.current.rotation, count));
    g.position.set(p.x, 0, p.z);
    g.rotation.y = p.rotY;
    g.scale.setScalar(p.scale);
    g.visible = p.visible;
    if (backingMat.current) backingMat.current.opacity = p.opacity;
    const front = frontRef.current;
    if (front) {
      const mat = front.material as THREE.Material & { opacity: number };
      mat.opacity = p.opacity;
    }
  });

  return (
    <group ref={group}>
      {/* 백킹 = 카드 두께 표현 — 이미지보다 살짝만 크게 (두꺼우면 액자처럼 투박해진다) */}
      <mesh position={[0, 0, -BACK_DEPTH / 2]}>
        <extrudeGeometry
          args={[BACK_SHAPE, { depth: BACK_DEPTH, bevelEnabled: false, curveSegments: 10 }]}
        />
        <meshStandardMaterial
          ref={backingMat}
          color="#ffffff"
          roughness={0.35}
          metalness={0.05}
          transparent
        />
      </mesh>
      {item.image ? (
        <CoverImageFront
          file={item.image.file}
          frontRef={frontRef}
          scale={[CARD_W, CARD_H]}
          position={[0, 0, 0.032]}
          radius={FRONT_R}
        />
      ) : (
        <mesh ref={frontRef} position={[0, 0, 0.032]}>
          <planeGeometry args={[CARD_W, CARD_H]} />
          <meshBasicMaterial map={canvasTexture} transparent toneMapped={false} />
        </mesh>
      )}
    </group>
  );
}

function DeckRig({
  deck,
  count,
  onFocalChange,
}: {
  deck: React.RefObject<DeckHandle>;
  count: number;
  onFocalChange: (i: number) => void;
}) {
  const focalRef = useRef(-1);

  useFrame((_, dt) => {
    const d = deck.current;
    if (!d) return;
    if (!d.dragging) {
      // 임계감쇠 스프링 등가 — 목표 인덱스로 수렴
      const k = 1 - Math.exp(-Math.min(dt, 0.05) * 9);
      d.rotation += (d.target - d.rotation) * k;
    }
    const focal = ((Math.round(d.rotation) % count) + count) % count;
    if (focal !== focalRef.current) {
      focalRef.current = focal;
      onFocalChange(focal);
    }
  });

  return null;
}

export default function CoverflowCanvas({
  items,
  deck,
  onFocalChange,
}: {
  items: ResolvedItem[];
  deck: React.RefObject<DeckHandle>;
  onFocalChange: (i: number) => void;
}) {
  return (
    <Canvas
      gl={{ alpha: true, antialias: true }}
      /* 1.5 캡은 레티나(dpr 2)에서 1.33x 업스케일 블러를 만든다 — 랜딩과 동일하게 [1, 2] */
      dpr={[1, 2]}
      camera={{ fov: 32, position: [0, 0.1, 7.2] }}
      style={{ position: "absolute", inset: 0 }}
      aria-hidden
    >
      <ambientLight intensity={1.15} />
      <directionalLight position={[4, 6, 6]} intensity={1.2} />
      <directionalLight position={[-6, -2, 4]} intensity={0.35} color="#B49AFF" />
      <Suspense fallback={null}>
        <group position={[0, 0.25, 0]}>
          {items.map((item, i) => (
            <CoverCard
              key={item.slug}
              item={item}
              index={i}
              count={items.length}
              deck={deck}
            />
          ))}
        </group>
      </Suspense>
      <ContactShadows
        position={[0, -CARD_H / 2 + 0.05, 0]}
        opacity={0.32}
        scale={13}
        blur={2.8}
        far={3.2}
        resolution={256}
        color="#17172A"
      />
      <DeckRig deck={deck} count={items.length} onFocalChange={onFocalChange} />
    </Canvas>
  );
}
