"use client";

import dynamic from "next/dynamic";
import Image from "next/image";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { ArrowRight } from "lucide-react";

const LandingCanvas = dynamic(() => import("./LandingCanvas"), { ssr: false });

/*
 * S0 히어로 — 미션 카피가 첫 화면. 텍스트·CTA 는 DOM(LCP), 기억 파편 필드는
 * 페인트 후 lazy R3F. CTA hover/focus 에 파편이 카피 둘레로 모여든다.
 * WebGL 불가·reduce-motion 은 정적 폴백 — 기능 손실 0.
 */

/** 폴백/모바일용 정적 파편 — 캔버스 없이도 공간감 유지 */
const STATIC_FRAGMENTS = [
  { src: "/seed/caps/yuna-cafe-window.jpg", className: "left-[6%] top-[16%] w-24 -rotate-6 md:w-32" },
  { src: "/seed/caps/sena-lms-os.jpg", className: "left-[13%] bottom-[14%] w-20 rotate-3 md:w-28" },
  { src: "/seed/caps/dohyun-k8s.jpg", className: "right-[7%] top-[18%] w-24 rotate-6 md:w-32" },
  { src: "/seed/caps/yuna-flower.jpg", className: "right-[13%] bottom-[13%] w-20 -rotate-3 md:w-28" },
];

export function LandingHero() {
  const reduce = useReducedMotion();
  const [webgl, setWebgl] = useState<boolean | null>(null);
  const [heroInView, setHeroInView] = useState(true);
  const sectionRef = useRef<HTMLElement>(null);
  const gatherTarget = useRef(0);
  const pointer = useRef({ x: 0, y: 0 });
  const hovering = useRef(false); // CTA hover 가 자동 사이클보다 우선

  useEffect(() => {
    try {
      const c = document.createElement("canvas");
      // eslint-disable-next-line react-hooks/set-state-in-effect -- 마운트 후 1회 WebGL 프로브
      setWebgl(Boolean(c.getContext("webgl2") ?? c.getContext("webgl")));
    } catch {
      setWebgl(false);
    }
  }, []);

  const canvasOn = webgl === true && !reduce;

  // 패럴랙스 포인터 수집 — 캔버스가 살아있을 때만 (폴백에선 전역 리스너 불필요)
  useEffect(() => {
    if (!canvasOn) return;
    const onMove = (e: PointerEvent) => {
      pointer.current = {
        x: (e.clientX / window.innerWidth) * 2 - 1,
        y: (e.clientY / window.innerHeight) * 2 - 1,
      };
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    return () => window.removeEventListener("pointermove", onMove);
  }, [canvasOn]);

  // 히어로가 화면 밖이면 프레임 루프 정지 — 아래 섹션을 읽는 동안 GPU 를 태우지 않는다
  useEffect(() => {
    if (!canvasOn || !sectionRef.current) return;
    const io = new IntersectionObserver(
      ([entry]) => setHeroInView(entry.isIntersecting),
      { threshold: 0.05 },
    );
    io.observe(sectionRef.current);
    return () => io.disconnect();
  }, [canvasOn]);

  // 자동 수렴 데모 — hover 를 발견하지 못해도 "떠오른다"가 한 번은 눈앞에서 일어난다.
  // 헤드라인을 읽을 시간 뒤 1회, 이후 긴 유휴에만 반복. reduce-motion 은 캔버스 자체가 꺼져 있다.
  useEffect(() => {
    if (!canvasOn) return;
    let pending = 0; // 사이클당 timeout 1개만 산다 — 새 사이클이 이전 것을 교체
    const cycle = () => {
      if (hovering.current) return;
      gatherTarget.current = 1;
      clearTimeout(pending);
      pending = window.setTimeout(() => {
        if (!hovering.current) gatherTarget.current = 0;
      }, 2600);
    };
    const first = window.setTimeout(cycle, 3200);
    const loop = window.setInterval(cycle, 18000);
    return () => {
      clearTimeout(first);
      clearTimeout(pending);
      clearInterval(loop);
    };
  }, [canvasOn]);

  return (
    <section ref={sectionRef} className="relative flex min-h-dvh flex-col overflow-hidden">
      {/* 배경 — 라벤더 안개 + 브랜드 글로우 */}
      <div
        className="absolute inset-0 bg-gradient-to-b from-lavender-200 via-lavender-300 to-bg"
        aria-hidden
      />
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(60% 42% at 50% 34%, rgb(255 255 255 / 0.55) 0%, transparent 70%), radial-gradient(90% 60% at 50% 108%, rgb(180 154 255 / 0.28) 0%, transparent 60%)",
        }}
        aria-hidden
      />

      {canvasOn ? (
        <motion.div
          className="absolute inset-0"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 1.1, ease: "easeOut" }}
        >
          <LandingCanvas
            gatherTargetRef={gatherTarget}
            pointerRef={pointer}
            paused={!heroInView}
          />
        </motion.div>
      ) : (
        webgl !== null && (
          <div aria-hidden>
            {STATIC_FRAGMENTS.map((f) => (
              /* eslint-disable-next-line @next/next/no-img-element -- 폴백 장식, LCP 무관 */
              <img
                key={f.src}
                src={f.src}
                alt=""
                className={`absolute rounded-xl opacity-70 shadow-card ring-1 ring-black/10 ${f.className}`}
              />
            ))}
          </div>
        )
      )}

      {/* 상단 로고 */}
      <header className="relative z-10 mx-auto flex w-full max-w-6xl items-center justify-between px-6 pt-6">
        <span className="flex items-center gap-2">
          <Image src="/brand/mochi2.png" alt="" width={30} height={30} priority />
          <span className="font-display text-[18px] tracking-head text-ink-900">모찌</span>
        </span>
        <Link
          href="/p"
          className="rounded-full border border-ink-900/10 bg-surface/60 px-4 py-1.5 text-[13px] font-semibold text-ink-700 backdrop-blur transition-colors hover:bg-surface"
        >
          바로 체험
        </Link>
      </header>

      {/* 미션 카피 — LCP */}
      <div className="relative z-10 mx-auto flex w-full max-w-3xl flex-1 flex-col items-center justify-center px-6 pb-24 text-center">
        <motion.p
          className="text-[13.5px] font-bold tracking-wide text-lavender-500"
          initial={reduce ? false : { opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, ease: "easeOut" }}
        >
          스크린샷 · 링크 · 기록을 맡아두는 기억 에이전트
        </motion.p>
        <motion.h1
          className="mt-4 font-display text-[clamp(28px,5vw,52px)] leading-[1.22] tracking-head text-lavender-900 [text-wrap:balance]"
          initial={reduce ? false : { opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: "easeOut", delay: 0.08 }}
        >
          놓치기 쉬운 순간은 쉽게 남기고,
          <br />
          필요한 기억은{" "}
          <span className="bg-gradient-to-r from-purple-500 to-purple-600 bg-clip-text text-transparent">
            쉽게 떠오른다
          </span>
        </motion.h1>
        <motion.p
          className="mt-5 max-w-xl text-[15px] leading-relaxed text-ink-700 md:text-[16.5px]"
          initial={reduce ? false : { opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: "easeOut", delay: 0.16 }}
        >
          보내기만 하면 정리는 모찌가 해요.
          필요한 순간엔 찾기 전에 이유와 함께 먼저 떠올라요.
        </motion.p>
        <motion.div
          className="mt-9 flex flex-col items-center gap-3"
          initial={reduce ? false : { opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: "easeOut", delay: 0.24 }}
          /* 수렴 트리거 — Link 는 prefetch 용으로 pointer 이벤트를 소비하므로 컨테이너에 건다 */
          onPointerEnter={() => {
            hovering.current = true;
            gatherTarget.current = 1;
          }}
          onPointerLeave={() => {
            hovering.current = false;
            gatherTarget.current = 0;
          }}
          onFocus={() => {
            hovering.current = true;
            gatherTarget.current = 1;
          }}
          onBlur={() => {
            hovering.current = false;
            gatherTarget.current = 0;
          }}
        >
          <Link
            href="/p"
            className="group inline-flex h-13 items-center gap-2 rounded-full bg-gradient-to-r from-purple-400 to-purple-600 px-8 text-[15.5px] font-bold text-white shadow-fab transition-transform hover:scale-[1.03] active:scale-[0.98]"
          >
            5분 만에 체험하기
            <ArrowRight
              className="size-4.5 transition-transform group-hover:translate-x-0.5"
              aria-hidden
            />
          </Link>
          <p className="text-[12.5px] font-medium text-ink-500">
            설치 없이 세 사람 중 한 명의 일주일을 체험해요
          </p>
        </motion.div>
      </div>

      {/* 스크롤 힌트 */}
      <div
        className="absolute inset-x-0 bottom-6 z-10 flex justify-center text-ink-300"
        aria-hidden
      >
        <motion.span
          className="text-[12px] font-semibold"
          animate={reduce ? undefined : { y: [0, 5, 0] }}
          transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
        >
          ↓ 미리 보기
        </motion.span>
      </div>
    </section>
  );
}
