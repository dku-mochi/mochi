"use client";

import { useRef, useState } from "react";
import Image from "next/image";
import { useReducedMotion } from "framer-motion";
import { cn } from "@/lib/cn";
import { SAMPLE_CARDS } from "@/seed/samples";
import { TINT_HEX } from "@/lib/types";
import type { SampleCard } from "@/lib/types";
import { BehaviorMark } from "@/components/ui";

/* ─────────────────────────────────────────────────────────────
   CSS 3D 코버플로우 — DOM 카드(또렷한 <img> + DOM 텍스트)로 iOS 회수 카드를 이식.
   WebGL 대신 CSS perspective/transform 을 써서 한글 텍스트·이미지가 선명하고,
   SSR/CSR 이 동일(스왑 없음). 드래그(관성 없이 즉답 + 스냅 transition) + 페이지 닷.
   ───────────────────────────────────────────────────────────── */

const N = SAMPLE_CARDS.length;
const CARD_W = 212;
const CARD_H = 268;
const STEP = CARD_W * 0.62; // 드래그 민감도 기준(한 칸 이동에 필요한 px)

function clamp(v: number, lo: number, hi: number) {
  return v < lo ? lo : v > hi ? hi : v;
}

function wrapOffset(i: number, focus: number) {
  let o = i - focus;
  o = ((o % N) + N) % N;
  if (o > N / 2) o -= N;
  return o;
}

function layoutFor(o: number) {
  const d = Math.abs(o);
  const s = o === 0 ? 0 : o > 0 ? 1 : -1;
  const x = s * (STEP * Math.min(d, 1) + STEP * 0.82 * Math.max(0, d - 1));
  const z = Math.max(0, 1 - d) * 52 - Math.min(d, 3) * 180;
  const ry = -clamp(o, -1, 1) * 46;
  const sc = Math.max(0.58, 1 - Math.min(d, 3) * 0.14);
  const op = d <= 1 ? 1 : Math.max(0, 1 - (d - 1) * 0.5);
  const zi = 100 - Math.round(d * 10);
  return { x, z, ry, sc, op, zi };
}

function CardInner({ card }: { card: SampleCard }) {
  const { soft, strong } = TINT_HEX[card.tint];
  const hasImage = !!card.imageUrl;
  return (
    <div className="relative h-full w-full overflow-hidden rounded-[20px] border border-black/5 bg-white shadow-[0_22px_46px_-14px_rgba(23,23,41,0.3)]">
      {hasImage ? (
        <Image
          src={card.imageUrl as string}
          alt=""
          fill
          sizes="220px"
          className="object-cover object-top"
          draggable={false}
        />
      ) : (
        <div className="absolute inset-0" style={{ background: `linear-gradient(155deg, ${soft}, ${strong})` }} />
      )}

      {/* 좌상단 행동 마크 — 글래스 배경으로 이미지 위에서도 또렷 */}
      <div className="absolute left-2.5 top-2.5 rounded-[11px] bg-white/80 p-1 shadow-sm backdrop-blur-md">
        <BehaviorMark intent={card.intents[0]} size="sm" />
      </div>

      {/* 하단 스크림 + 제목/출처 */}
      <div
        className="absolute inset-x-0 bottom-0 p-3.5 pt-10"
        style={{
          background: hasImage
            ? "linear-gradient(to top, rgba(0,0,0,0.74), rgba(0,0,0,0.16) 58%, transparent)"
            : "linear-gradient(to top, rgba(0,0,0,0.26), transparent)",
        }}
      >
        <p className="line-clamp-2 text-[13.5px] font-extrabold leading-snug tracking-tight text-white">
          {card.title}
        </p>
        {card.source ? (
          <p className="mt-1 text-[11px] font-medium text-white/75">{card.source}</p>
        ) : null}
      </div>
    </div>
  );
}

export function CoverflowCSS() {
  useReducedMotion(); // 모션 축소는 globals.css 미디어쿼리가 transition 을 무력화
  const [focus, setFocus] = useState(0); // 정수 초점
  const [drag, setDrag] = useState(0); // 드래그 중 실수 offset
  const [isDragging, setIsDragging] = useState(false);
  const dragging = useRef(false);
  const startX = useRef(0);
  const moved = useRef(false);

  const effective = focus - drag;

  const onDown = (e: React.PointerEvent) => {
    dragging.current = true;
    moved.current = false;
    setIsDragging(true);
    startX.current = e.clientX;
    (e.currentTarget as Element).setPointerCapture?.(e.pointerId);
  };
  const onMove = (e: React.PointerEvent) => {
    if (!dragging.current) return;
    const dx = e.clientX - startX.current;
    if (Math.abs(dx) > 3) moved.current = true;
    setDrag(dx / STEP);
  };
  const onUp = (e: React.PointerEvent) => {
    if (!dragging.current) return;
    dragging.current = false;
    setIsDragging(false);
    setFocus((f) => Math.round(f - drag));
    setDrag(0);
    (e.currentTarget as Element).releasePointerCapture?.(e.pointerId);
  };

  return (
    <div className="relative h-full w-full">
      <div
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerLeave={onUp}
        onPointerCancel={onUp}
        className="relative h-full w-full touch-none select-none"
        style={{ perspective: "1500px", cursor: isDragging ? "grabbing" : "grab" }}
      >
        {SAMPLE_CARDS.map((card, i) => {
          const t = layoutFor(wrapOffset(i, effective));
          return (
            <div
              key={card.id}
              aria-hidden={Math.abs(wrapOffset(i, focus)) > 0.5}
              style={{
                position: "absolute",
                width: CARD_W,
                height: CARD_H,
                left: `calc(50% - ${CARD_W / 2}px)`,
                top: `calc(50% - ${CARD_H / 2}px)`,
                transform: `translate3d(${t.x}px, 0, ${t.z}px) rotateY(${t.ry}deg) scale(${t.sc})`,
                opacity: t.op,
                zIndex: t.zi,
                transition: isDragging
                  ? "none"
                  : "transform 0.55s cubic-bezier(0.16,1,0.3,1), opacity 0.5s ease",
                transformStyle: "preserve-3d",
                willChange: "transform",
              }}
            >
              <CardInner card={card} />
            </div>
          );
        })}
      </div>

      {/* 페이지 닷 */}
      <div className="pointer-events-auto absolute inset-x-0 bottom-0 flex justify-center gap-1.5">
        {SAMPLE_CARDS.map((card, i) => {
          const active = (((focus % N) + N) % N) === i;
          return (
            <button
              key={card.id}
              aria-label={`${i + 1}번째 카드 보기`}
              onClick={() => setFocus(i)}
              className={cn(
                "h-1.5 rounded-full transition-all",
                active ? "w-5 bg-purple-500" : "w-1.5 bg-ink-300/50 hover:bg-ink-300",
              )}
            />
          );
        })}
      </div>
    </div>
  );
}
