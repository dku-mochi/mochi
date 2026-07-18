"use client";

import Image from "next/image";
import Link from "next/link";
import {
  useCallback,
  useEffect,
  forwardRef,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import {
  ArrowRight,
  BookOpen,
  Calendar,
  Camera,
  Check,
  FileText,
  GripVertical,
  ImagePlus,
  Inbox,
  Link2,
  ListChecks,
  Send,
  X,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { usePersona } from "@/components/journey/PersonaProvider";
import {
  calendarEntries,
  dday,
  kstParts,
  relativeLabel,
  type ResolvedItem,
} from "@/lib/seedRuntime";
import {
  captureThumb,
  prepareCaptureImage,
  type CaptureThumb,
} from "@/lib/captureImage";
import { makeLiveEntry, type LiveCaptureInput } from "@/lib/liveOverlay";
import { markJourneyStep } from "@/lib/journeySession";
import type { CaptureExample } from "@/lib/captureExamples";
import { useLiveAnalysis, STAGE_LABEL, type AnalysisStage } from "@/lib/hooks/useLiveAnalysis";
import { MiniCalendar } from "@/components/primitives/MiniCalendar";
import { RiseIn } from "@/components/primitives/RiseIn";
import { IntentChip } from "@/components/primitives/IntentChip";
import { domainOf } from "@/components/tiles/ItemTile";
import { cn } from "@/lib/cn";

/*
 * S2 기록 씬 — "캡처는 0노력, 정리는 자동".
 * 좌: 직접 보내기 컴포저.
 * 우: 보낸 것이 꽂히는 보드 4칸 — 할 일 · 캘린더(클릭) · 지식 · 기록.
 * 분류를 자랑하지 않는다: 어떤 intent 든 "기록"에는 반드시 쌓인다(사라지는 캡처 없음).
 * 직접 보낸 것은 세션 오버레이(liveOverlay)로 홈까지 이어진다.
 */

export function CaptureScene({ examples }: { examples: CaptureExample[] }) {
  const { persona, liveItems, liveSlugs, now } = usePersona();
  const [draggedExample, setDraggedExample] = useState<CaptureExample | null>(null);
  const [dragPoint, setDragPoint] = useState<{ x: number; y: number } | null>(null);
  const [exampleDragOver, setExampleDragOver] = useState(false);
  const composerRef = useRef<LiveComposerHandle>(null);

  const moveExample = (example: CaptureExample, x: number, y: number) => {
    setDraggedExample(example);
    setDragPoint({ x, y });
    setExampleDragOver(composerRef.current?.containsPoint(x, y) ?? false);
  };

  const finishExample = (example: CaptureExample, x: number, y: number) => {
    if (composerRef.current?.containsPoint(x, y)) {
      composerRef.current.applyExample(example);
    }
    setDraggedExample(null);
    setDragPoint(null);
    setExampleDragOver(false);
  };

  return (
    <main className="mx-auto max-w-6xl px-5 py-8">
      <RiseIn index={0}>
        <h1 className="font-display text-[24px] tracking-head">보내기만 하세요</h1>
        <p className="mt-1.5 max-w-xl text-[14px] leading-relaxed text-ink-500">
          스크린샷·링크·메모가 들어오면, 모찌가 할 일과 마감으로 만들어 제자리에 꽂아둬요.
        </p>
      </RiseIn>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-12">
        {/* ── 좌: 보내는 무대 — 우측 보드와 등고 ── */}
        <div className="lg:col-span-5">
          <RiseIn index={1} className="h-full">
            <div className="relative flex h-full min-h-[478px] flex-col rounded-3xl border border-ink-100 bg-surface p-6 shadow-card">
              <LiveComposer
                ref={composerRef}
                homeHref={`/p/${persona.slug}`}
                exampleDragOver={exampleDragOver}
              />
            </div>
          </RiseIn>
        </div>

        {/* ── 우: 꽂히는 보드 ── */}
        <div className="lg:col-span-7">
          <div className="grid auto-rows-fr grid-cols-1 gap-4 sm:grid-cols-2">
            <RiseIn index={2} className="h-full">
              <BoardTodos items={liveItems} now={now} />
            </RiseIn>
            <RiseIn index={3} className="h-full">
              <BoardCalendar items={liveItems} now={now} personaSlug={persona.slug} />
            </RiseIn>
            <RiseIn index={4} className="h-full">
              <BoardKnowledge items={liveItems} personaSlug={persona.slug} />
            </RiseIn>
            <RiseIn index={5} className="h-full">
              <BoardInbox
                items={liveItems}
                liveSlugs={liveSlugs}
                now={now}
                personaSlug={persona.slug}
              />
            </RiseIn>
          </div>
        </div>
      </div>

      <RiseIn index={6}>
        <CaptureExamples
          examples={examples}
          onDragMove={moveExample}
          onDragEnd={finishExample}
          onDragCancel={() => {
            setDraggedExample(null);
            setDragPoint(null);
            setExampleDragOver(false);
          }}
        />
      </RiseIn>

      <AnimatePresence>
        {draggedExample && dragPoint && (
          <motion.div
            className="pointer-events-none fixed z-[70] w-28 overflow-hidden rounded-xl border border-purple-200 bg-surface shadow-card-lift"
            style={{ left: dragPoint.x, top: dragPoint.y }}
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 0.92, scale: 1, x: 14, y: 14 }}
            exit={{ opacity: 0, scale: 0.94 }}
            aria-hidden
          >
            {draggedExample.kind === "memo" ? (
              <p className="line-clamp-4 min-h-24 bg-butter-50 p-3 text-[11.5px] font-semibold leading-relaxed text-ink-900">
                {draggedExample.text}
              </p>
            ) : (
              <Image
                src={draggedExample.image.file}
                alt=""
                width={draggedExample.image.width}
                height={draggedExample.image.height}
                className="h-24 w-full object-cover object-top"
              />
            )}
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}

const EXAMPLE_TABS = [
  { kind: "screenshot", label: "스크린샷", Icon: Camera },
  { kind: "url", label: "링크", Icon: Link2 },
  { kind: "memo", label: "메모", Icon: FileText },
] as const;

function CaptureExamples({
  examples,
  onDragMove,
  onDragEnd,
  onDragCancel,
}: {
  examples: CaptureExample[];
  onDragMove: (example: CaptureExample, x: number, y: number) => void;
  onDragEnd: (example: CaptureExample, x: number, y: number) => void;
  onDragCancel: () => void;
}) {
  const reduce = useReducedMotion();
  const [active, setActive] = useState<CaptureExample["kind"]>("screenshot");
  const pointerDrag = useRef<{
    pointerId: number;
    startX: number;
    startY: number;
    clientX: number;
    clientY: number;
    example: CaptureExample;
    moved: boolean;
  } | null>(null);
  const autoScrollFrame = useRef<number | null>(null);
  const visible = examples.filter((example) => example.kind === active);

  const stopAutoScroll = () => {
    if (autoScrollFrame.current !== null) cancelAnimationFrame(autoScrollFrame.current);
    autoScrollFrame.current = null;
  };

  const keepAutoScrolling = () => {
    if (autoScrollFrame.current !== null) return;
    const tick = () => {
      const drag = pointerDrag.current;
      if (!drag?.moved) {
        autoScrollFrame.current = null;
        return;
      }
      const edge = 88;
      const delta =
        drag.clientY < edge
          ? -Math.ceil((edge - drag.clientY) / 5)
          : drag.clientY > window.innerHeight - edge
            ? Math.ceil((drag.clientY - (window.innerHeight - edge)) / 5)
            : 0;
      if (delta === 0) {
        autoScrollFrame.current = null;
        return;
      }
      window.scrollBy(0, delta);
      onDragMove(drag.example, drag.clientX, drag.clientY);
      autoScrollFrame.current = requestAnimationFrame(tick);
    };
    autoScrollFrame.current = requestAnimationFrame(tick);
  };

  useEffect(
    () => () => {
      if (autoScrollFrame.current !== null) cancelAnimationFrame(autoScrollFrame.current);
    },
    [],
  );

  const startPointerDrag = (event: ReactPointerEvent<HTMLElement>, example: CaptureExample) => {
    stopAutoScroll();
    event.currentTarget.setPointerCapture(event.pointerId);
    pointerDrag.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      clientX: event.clientX,
      clientY: event.clientY,
      example,
      moved: false,
    };
  };

  const movePointerDrag = (event: ReactPointerEvent<HTMLElement>) => {
    const drag = pointerDrag.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    drag.clientX = event.clientX;
    drag.clientY = event.clientY;
    event.preventDefault();
    if (Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 10) return;
    if (!drag.moved) {
      drag.moved = true;
    }
    onDragMove(drag.example, event.clientX, event.clientY);
    keepAutoScrolling();
  };

  const finishPointerDrag = (event: ReactPointerEvent<HTMLElement>) => {
    const drag = pointerDrag.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    pointerDrag.current = null;
    stopAutoScroll();
    if (drag.moved) {
      onDragEnd(drag.example, event.clientX, event.clientY);
    }
  };

  const cancelPointerDrag = (event: ReactPointerEvent<HTMLElement>) => {
    if (pointerDrag.current?.pointerId === event.pointerId) pointerDrag.current = null;
    stopAutoScroll();
    onDragCancel();
  };

  return (
    <section aria-label="직접 입력 예시" className="mt-10 border-t border-ink-100 pt-7">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-[12px] font-bold text-purple-600">직접 보내기 예시</p>
          <h2 className="mt-1 font-display text-[20px] tracking-head">이런 순간을 맡겨보세요</h2>
          <p className="mt-1.5 text-[12.5px] text-ink-500">
            마우스를 올려 크게 보고, 카드째 위 입력창으로 끌어다 놓아보세요.
          </p>
        </div>
        <div
          role="tablist"
          aria-label="예시 종류"
          className="flex w-fit items-center gap-1 rounded-full bg-ink-100/70 p-1"
        >
          {EXAMPLE_TABS.map(({ kind, label, Icon }) => (
            <button
              key={kind}
              type="button"
              role="tab"
              aria-selected={active === kind}
              aria-controls="capture-example-panel"
              onClick={() => setActive(kind)}
              className={cn(
                "inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-[12.5px] font-bold transition-colors",
                active === kind
                  ? "bg-surface text-ink-900 shadow-card"
                  : "text-ink-500 hover:text-ink-900",
              )}
            >
              <Icon className="size-3.5" aria-hidden />
              {label}
            </button>
          ))}
        </div>
      </div>

      <div
        id="capture-example-panel"
        role="tabpanel"
        className={cn(
          "mt-5 grid gap-3.5 py-2",
          active === "screenshot"
            ? "grid-cols-2 sm:grid-cols-3 lg:grid-cols-5"
            : "grid-cols-2 md:grid-cols-3",
        )}
      >
        {visible.map((example) => (
            <motion.div
              key={example.id}
              draggable={false}
              role="img"
              aria-label={`${example.title}. 입력창으로 끌어다 놓을 수 있는 예시`}
              title="입력창으로 끌어다 놓기"
              onPointerDown={(event) => {
                if (event.pointerType === "mouse") startPointerDrag(event, example);
              }}
              onPointerMove={movePointerDrag}
              onPointerUp={finishPointerDrag}
              onPointerCancel={cancelPointerDrag}
              whileHover={reduce ? undefined : { scale: 1.015, y: -2 }}
              transition={{ type: "spring", stiffness: 380, damping: 30, mass: 0.55 }}
              className="group relative z-0 min-w-0 origin-center cursor-grab select-none overflow-hidden rounded-2xl border border-ink-100 bg-surface text-left shadow-card transition-[border-color,box-shadow] duration-200 ease-out hover:z-20 hover:border-purple-200 hover:shadow-card-lift active:cursor-grabbing"
            >
              <>
                  <span
                    data-example-drag-handle
                    className="absolute right-2 top-2 z-10 flex size-7 touch-none items-center justify-center rounded-lg bg-surface/90 text-ink-500 shadow-card backdrop-blur sm:hidden"
                    aria-hidden
                    onPointerDown={(event) => {
                      if (event.pointerType !== "mouse") {
                        event.stopPropagation();
                        startPointerDrag(event, example);
                      }
                    }}
                    onPointerMove={movePointerDrag}
                    onPointerUp={finishPointerDrag}
                    onPointerCancel={cancelPointerDrag}
                  >
                    <GripVertical className="size-3.5" />
                  </span>
                  {example.kind === "screenshot" ? (
                    <>
                      <Image
                        src={example.image.file}
                        alt={example.title}
                        width={example.image.width}
                        height={example.image.height}
                        draggable={false}
                        className="aspect-[0.85] w-full object-cover object-top transition-transform duration-300 group-hover:scale-[1.02]"
                      />
                      <span className="block min-h-14 px-3 py-2.5 text-[12.5px] font-bold leading-snug">
                        {example.title}
                      </span>
                    </>
                  ) : example.kind === "url" ? (
                    <>
                      <div className="relative aspect-[2/1] overflow-hidden bg-purple-50">
                        <Image
                          src={example.image.file}
                          alt=""
                          fill
                          sizes="224px"
                          draggable={false}
                          className="object-cover object-top"
                        />
                        <span className="absolute bottom-2 left-2 flex size-7 items-center justify-center rounded-lg bg-surface/90 shadow-card backdrop-blur">
                          <Link2 className="size-3.5 text-purple-600" aria-hidden />
                        </span>
                      </div>
                      <span className="block px-3 py-2.5">
                        <span className="line-clamp-2 min-h-9 text-[12.5px] font-bold leading-snug">
                          {example.title}
                        </span>
                        <span className="mt-1 block truncate text-[11px] font-medium text-purple-600">
                          {domainOf(example.url)}
                        </span>
                      </span>
                    </>
                  ) : (
                    <span className="flex h-[170px] flex-col bg-butter-50 p-4">
                      <FileText className="size-4 text-butter-400" aria-hidden />
                      <span className="mt-3 line-clamp-4 text-[13px] font-semibold leading-relaxed text-ink-900">
                        {example.text}
                      </span>
                      <span className="mt-auto truncate pt-2 text-[11px] font-bold text-[#8A6410]">
                        {example.title}
                      </span>
                    </span>
                  )}
              </>
            </motion.div>
        ))}
      </div>
    </section>
  );
}

/* ── 직접 보내기 컴포저 — 입력·첨부·드롭·붙여넣기 → 진행 → 착지 ── */

const IMAGE_TYPES = /^image\/(png|jpeg|webp)$/;
const PROGRESS_STAGES = ["sending", "ingested", "normalized", "analyzing"] as const;
// BFF 수용 상한과 동일 — 초과분이 서버에서 조용히 잘리는 일이 없게 입력단에서 막는다
const MAX_TEXT = 2000;
const COUNTER_FROM = 1800;

interface Attachment {
  blob: Blob;
  thumb: CaptureThumb | null;
  previewUrl: string;
}

interface LiveComposerHandle {
  applyExample: (example: CaptureExample) => void;
  containsPoint: (x: number, y: number) => boolean;
}

const LiveComposer = forwardRef<LiveComposerHandle, {
  homeHref: string;
  exampleDragOver: boolean;
}>(function LiveComposer({
  homeHref,
  exampleDragOver,
}, ref) {
  const { persona, addLiveCapture } = usePersona();
  const live = useLiveAnalysis(persona.slug);
  const resetLive = live.reset;
  const reduce = useReducedMotion();
  const [text, setText] = useState("");
  const [attach, setAttach] = useState<Attachment | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const composerRootRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const pendingRef = useRef<LiveCaptureInput | null>(null);
  const savedIdsRef = useRef(new Set<string>());
  const exampleAbortRef = useRef<AbortController | null>(null);
  const appliedExampleRef = useRef<CaptureExample | null>(null);

  const running =
    live.stage !== "idle" && live.stage !== "done" && live.stage !== "failed";
  const canSend = !running && !preparing && (Boolean(text.trim()) || Boolean(attach));

  // 언마운트 시 미리보기 URL 정리 — 빈 deps 클로저는 첫 렌더의 null 을 캡처하므로 ref 로 현재값을 본다
  const attachRef = useRef<Attachment | null>(null);
  useEffect(() => {
    attachRef.current = attach;
  }, [attach]);
  useEffect(
    () => () => {
      exampleAbortRef.current?.abort();
      if (attachRef.current) URL.revokeObjectURL(attachRef.current.previewUrl);
    },
    [],
  );

  // 분석 완료 → 세션 오버레이에 착지 (홈·검색·캘린더로 이어진다)
  useEffect(() => {
    if (live.stage !== "done" || !live.result) return;
    const sent = pendingRef.current;
    if (!sent || savedIdsRef.current.has(live.result.id)) return;
    savedIdsRef.current.add(live.result.id);
    const entry = makeLiveEntry(live.result, sent);
    addLiveCapture(entry);
    markJourneyStep(persona.slug, "capture", {
      capture: { slug: entry.slug, title: entry.wire.title },
    });
  }, [live.stage, live.result, addLiveCapture, persona.slug]);

  const acceptFile = useCallback(async (file: File) => {
    if (!IMAGE_TYPES.test(file.type)) return;
    setPreparing(true);
    try {
      let blob: Blob = file;
      try {
        blob = await prepareCaptureImage(file);
      } catch {
        // 재인코딩 불가 포맷 — 원본 그대로, 서버 검증이 최종 판정
      }
      const thumb = await captureThumb(blob);
      setAttach((prev) => {
        if (prev) URL.revokeObjectURL(prev.previewUrl);
        return { blob, thumb, previewUrl: URL.createObjectURL(blob) };
      });
    } finally {
      setPreparing(false);
    }
  }, []);

  const clearAttach = useCallback(() => {
    setAttach((prev) => {
      if (prev) URL.revokeObjectURL(prev.previewUrl);
      return null;
    });
  }, []);

  const revealComposer = useCallback((focusText: boolean) => {
    requestAnimationFrame(() => {
      composerRootRef.current?.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
      if (focusText) textareaRef.current?.focus({ preventScroll: true });
    });
  }, [reduce]);

  const applyExample = useCallback(
    (example: CaptureExample) => {
      if (running) return;
      exampleAbortRef.current?.abort();
      resetLive();
      pendingRef.current = null;
      clearAttach();
      appliedExampleRef.current = example;

      if (example.kind === "memo") {
        setText(example.text);
        revealComposer(true);
        return;
      }
      if (example.kind === "url") {
        setText(example.url);
        revealComposer(true);
        return;
      }

      setText("");
      revealComposer(false);
      const ac = new AbortController();
      exampleAbortRef.current = ac;
      void fetch(example.image.file, { signal: ac.signal })
        .then((response) => (response.ok ? response.blob() : null))
        .then((blob) => {
          if (!blob || ac.signal.aborted) return;
          const mime = IMAGE_TYPES.test(blob.type) ? blob.type : "image/jpeg";
          return acceptFile(new File([blob], `${example.id}.jpg`, { type: mime }));
        })
        .catch(() => undefined);
    },
    [acceptFile, clearAttach, resetLive, revealComposer, running],
  );

  useImperativeHandle(
    ref,
    () => ({
      applyExample,
      containsPoint: (x, y) => {
        if (running || preparing) return false;
        const rect = composerRootRef.current?.getBoundingClientRect();
        return Boolean(rect && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom);
      },
    }),
    [applyExample, preparing, running],
  );

  const send = () => {
    const trimmed = text.trim();
    if (!canSend) return;
    if (attach) {
      pendingRef.current = {
        kind: "screenshot",
        memo: trimmed || undefined,
        thumb: attach.thumb ?? undefined,
        place: appliedExampleRef.current?.place,
        retrievalHint: appliedExampleRef.current?.title,
      };
      void live.run({ imageFile: attach.blob, memo: trimmed || undefined });
    } else if (/^https?:\/\//.test(trimmed)) {
      pendingRef.current = {
        kind: "url",
        url: trimmed,
        place: appliedExampleRef.current?.place,
        retrievalHint: appliedExampleRef.current?.title,
      };
      void live.run({ url: trimmed });
    } else {
      pendingRef.current = {
        kind: "memo",
        text: trimmed,
        place: appliedExampleRef.current?.place,
        retrievalHint: appliedExampleRef.current?.title,
      };
      void live.run({ text: trimmed });
    }
  };

  const sendAnother = () => {
    live.reset();
    setText("");
    clearAttach();
    pendingRef.current = null;
    appliedExampleRef.current = null;
  };

  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const file = [...e.dataTransfer.files].find((f) => IMAGE_TYPES.test(f.type));
    if (file && !preparing && !running) {
      appliedExampleRef.current = null;
      void acceptFile(file);
    }
  };

  return (
    <motion.div
      ref={composerRootRef}
      className="relative flex flex-1 flex-col"
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ type: "spring", duration: 0.5, bounce: 0.15 }}
      onDragOver={(e) => {
        const types = [...e.dataTransfer.types];
        if (types.includes("Files")) {
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
          if (!running && !preparing) setDragOver(true);
        }
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node)) setDragOver(false);
      }}
      onDrop={onDrop}
      onPaste={(e) => {
        const file = [...e.clipboardData.files].find((f) => IMAGE_TYPES.test(f.type));
        if (file && !preparing && !running) {
          e.preventDefault();
          appliedExampleRef.current = null;
          void acceptFile(file);
        }
      }}
    >
      <h2 className="text-[18px] font-extrabold tracking-snug">
        직접 보내보세요
      </h2>
      <p className="mt-1 text-[13px] leading-relaxed text-ink-500">
        직접 적거나, 아래 예시를 이곳으로 끌어와도 좋아요.
      </p>

      {running && live.stage !== "idle" ? (
        <ProgressTimeline stage={live.stage} echoText={text} echoImage={attach?.previewUrl} />
      ) : live.stage === "done" && live.result ? (
        <ResultCard
          result={live.result}
          homeHref={homeHref}
          onMore={sendAnother}
        />
      ) : (
        <>
          {live.stage === "failed" && (
            <p className="mt-3 rounded-xl bg-blush-100/60 px-3.5 py-2.5 text-[12.5px] font-semibold text-blush-400">
              연결이 잠시 고르지 않네요. 다시 보내주세요.
            </p>
          )}
          <div className="mt-4 flex flex-1 flex-col rounded-2xl border border-ink-100 bg-bg/60 transition-colors focus-within:border-purple-200">
            {attach && (
              <div className="flex items-center gap-3 border-b border-ink-100/70 px-4 pb-3 pt-4">
                {/* 첨부 미리보기는 로컬 blob — next/image 최적화 대상이 아니다 */}
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={attach.previewUrl}
                  alt="첨부한 스크린샷 미리보기"
                  className="h-16 w-16 flex-none rounded-lg object-cover ring-1 ring-black/10"
                />
                <div className="min-w-0 flex-1">
                  <p className="text-[13px] font-bold text-ink-900">스크린샷 1장</p>
                  <p className="mt-0.5 text-[11.5px] text-ink-500">
                    아래에 메모를 붙여도 좋아요
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => {
                    clearAttach();
                    appliedExampleRef.current = null;
                  }}
                  aria-label="첨부 제거"
                  className="flex size-7 flex-none items-center justify-center rounded-full text-ink-300 transition-colors hover:bg-ink-100/70 hover:text-ink-700"
                >
                  <X className="size-3.5" aria-hidden />
                </button>
              </div>
            )}
            <textarea
              ref={textareaRef}
              value={text}
              onChange={(e) => {
                const next = e.target.value;
                const applied = appliedExampleRef.current;
                if (
                  applied &&
                  applied.kind !== "screenshot" &&
                  next !== (applied.kind === "url" ? applied.url : applied.text)
                ) {
                  appliedExampleRef.current = null;
                }
                setText(next);
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  send();
                }
              }}
              rows={attach ? 2 : 4}
              maxLength={MAX_TEXT}
              placeholder={
                attach
                  ? "예: 다음 주에 가고 싶던 곳 (선택)"
                  : "예: 금요일 3시 팀 미팅 준비하기"
              }
              aria-label="모찌에게 보낼 내용"
              className="w-full flex-1 resize-none bg-transparent px-4 py-3.5 text-[14px] leading-relaxed outline-none placeholder:text-ink-300"
            />
            <div className="flex items-center justify-between gap-2 px-3 pb-3">
              <input
                ref={fileRef}
                type="file"
                accept="image/png,image/jpeg,image/webp"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  e.target.value = ""; // 같은 파일 재선택 허용
                  if (file && !preparing && !running) {
                    appliedExampleRef.current = null;
                    void acceptFile(file);
                  }
                }}
              />
              <button
                type="button"
                onClick={() => fileRef.current?.click()}
                disabled={preparing || running}
                className="inline-flex h-9 items-center gap-1.5 rounded-full border border-ink-100 bg-surface px-3.5 text-[12.5px] font-bold text-ink-700 transition-[background-color,border-color,transform] hover:border-purple-200 hover:bg-purple-50 active:scale-[0.97] disabled:opacity-50"
              >
                <ImagePlus className="size-3.5 text-purple-500" aria-hidden />
                {preparing ? "준비 중…" : "스크린샷"}
              </button>
              {text.length >= COUNTER_FROM && (
                <span className="text-[11px] font-medium text-ink-300 tnum" aria-live="polite">
                  {text.length.toLocaleString()} / {MAX_TEXT.toLocaleString()}
                </span>
              )}
              <button
                type="button"
                onClick={send}
                disabled={!canSend}
                className="inline-flex h-10 items-center gap-2 rounded-full bg-gradient-to-r from-purple-400 to-purple-600 px-5 text-[13.5px] font-bold text-white shadow-fab transition-transform active:scale-[0.97] disabled:opacity-45 disabled:shadow-none"
              >
                <Send className="size-3.5" aria-hidden /> 모찌에게 보내기
              </button>
            </div>
          </div>
          <p className="mt-3 text-center text-[12.5px] font-bold text-purple-600">
            아래의 예시에서 끌어와 넣어보세요!
          </p>
        </>
      )}

      {/* 드래그 오버레이 */}
      <AnimatePresence>
        {(dragOver || exampleDragOver) && (
          <motion.div
            className="pointer-events-none absolute -inset-2 z-10 flex items-center justify-center rounded-3xl border-2 border-dashed border-purple-400 bg-purple-50/90 backdrop-blur-[2px]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
          >
            <p className="flex items-center gap-2 text-[14.5px] font-bold text-purple-600">
              <ImagePlus className="size-4.5" aria-hidden /> 여기에 놓으면 모찌가 받아요
            </p>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
});

/** 진행 타임라인 — 단계가 눈앞에서 하나씩 접히는 "AI 가 일하는 중" */
function ProgressTimeline({
  stage,
  echoText,
  echoImage,
}: {
  stage: AnalysisStage;
  echoText: string;
  echoImage?: string;
}) {
  const reduce = useReducedMotion();
  const currentIdx = PROGRESS_STAGES.indexOf(stage as (typeof PROGRESS_STAGES)[number]);
  return (
    <div className="mt-4 flex flex-1 flex-col">
      {/* 보낸 내용 에코 — 무엇이 처리되는지 눈에 보이게 */}
      <div className="flex items-center gap-3 rounded-2xl bg-bg/70 px-4 py-3">
        {echoImage ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={echoImage}
            alt=""
            aria-hidden
            className="h-11 w-11 flex-none rounded-lg object-cover ring-1 ring-black/10"
          />
        ) : (
          <span className="flex size-9 flex-none items-center justify-center rounded-lg bg-surface shadow-card">
            <FileText className="size-4 text-ink-500" aria-hidden />
          </span>
        )}
        <p className="line-clamp-2 min-w-0 text-[13px] font-medium text-ink-700">
          {echoText.trim() || "스크린샷 1장"}
        </p>
      </div>

      <ol className="mt-5 space-y-3.5" aria-label="분석 진행">
        {PROGRESS_STAGES.map((s, i) => {
          const state = i < currentIdx ? "done" : i === currentIdx ? "active" : "todo";
          return (
            <li key={s} className="flex items-center gap-3">
              <span
                className={cn(
                  "flex size-6 flex-none items-center justify-center rounded-full transition-colors duration-300",
                  state === "done" && "bg-mint-100",
                  state === "active" && "bg-purple-100",
                  state === "todo" && "bg-bg",
                )}
              >
                {state === "done" ? (
                  <Check className="size-3.5 text-mint-400" strokeWidth={3} aria-hidden />
                ) : state === "active" ? (
                  <motion.i
                    className="size-2 rounded-full bg-purple-500"
                    animate={reduce ? undefined : { scale: [1, 1.5, 1], opacity: [1, 0.55, 1] }}
                    transition={{ duration: 1.1, repeat: Infinity, ease: "easeInOut" }}
                  />
                ) : (
                  <i className="size-1.5 rounded-full bg-ink-300/60" />
                )}
              </span>
              <span
                className={cn(
                  "text-[13.5px] transition-colors duration-300",
                  state === "done" && "font-medium text-ink-500",
                  state === "active" && "font-bold text-ink-900",
                  state === "todo" && "font-medium text-ink-300",
                )}
              >
                {STAGE_LABEL[s]}
              </span>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

/** 분석 착지 카드 — 무엇으로 정리됐고 어디에 꽂혔는지 */
function ResultCard({
  result,
  homeHref,
  onMore,
}: {
  result: NonNullable<ReturnType<typeof useLiveAnalysis>["result"]>;
  homeHref: string;
  onMore: () => void;
}) {
  const intentTypes = [...new Set(result.intents.map((i) => i.intentType))];
  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ type: "spring", duration: 0.5, bounce: 0.2 }}
      className="mt-4 flex flex-1 flex-col"
    >
      <div className="rounded-2xl bg-mint-100/60 p-5">
        <p className="flex items-center gap-1.5 text-[12.5px] font-bold text-[#187A4E]">
          <Check className="size-3.5" strokeWidth={3} aria-hidden />
          정리해서 꽂아뒀어요
        </p>
        <p className="mt-2.5 text-[15.5px] font-bold leading-snug text-ink-900">
          {result.title}
        </p>
        <p className="mt-1.5 text-[13px] leading-relaxed text-ink-700">
          {result.summary}
        </p>
        {intentTypes.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {intentTypes.map((t) => (
              <IntentChip key={t} intent={t} size="sm" />
            ))}
          </div>
        )}
      </div>
      <div className="mt-4 flex items-center gap-2.5">
        <button
          onClick={onMore}
          className="h-10 flex-1 rounded-full border border-ink-100 bg-surface text-[13px] font-bold text-ink-700 transition-[background-color,border-color,transform] hover:border-purple-200 hover:bg-purple-50 active:scale-[0.97]"
        >
          하나 더 보내기
        </button>
        <Link
          href={homeHref}
          className="inline-flex h-10 flex-1 items-center justify-center gap-1 rounded-full bg-ink-900 text-[13px] font-bold text-white transition-[background-color,transform] hover:bg-ink-700 active:scale-[0.97]"
        >
          홈에 쌓인 모습 보기 <ArrowRight className="size-3.5" aria-hidden />
        </Link>
      </div>
      <p className="mt-3 text-center text-[11.5px] leading-relaxed text-ink-300">
        방금 보낸 기록은 이 브라우저의 홈·검색·캘린더에 그대로 쌓여요
      </p>
    </motion.div>
  );
}

/* ── 보드 4칸 — 등고 카드 ── */

function BoardCard({
  Icon,
  iconBg,
  iconColor,
  title,
  count,
  footer,
  children,
}: {
  Icon: LucideIcon;
  iconBg: string;
  iconColor: string;
  title: string;
  count?: number;
  footer?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section
      aria-label={title}
      className="flex h-full flex-col rounded-2xl border border-ink-100 bg-surface p-4 shadow-card"
    >
      <header className="flex items-center gap-2">
        <span className={cn("flex size-7 flex-none items-center justify-center rounded-lg", iconBg)}>
          <Icon className={cn("size-4", iconColor)} strokeWidth={2.4} aria-hidden />
        </span>
        <h2 className="text-[14.5px] font-extrabold tracking-snug">{title}</h2>
        {count !== undefined && count > 0 && (
          <span className="ml-auto rounded-full bg-bg px-2 py-0.5 text-[11px] font-bold text-ink-500 tnum">
            {count}
          </span>
        )}
      </header>
      <div className="mt-3 flex min-h-0 flex-1 flex-col">{children}</div>
      {footer}
    </section>
  );
}

/** 빈 보드 = 준비된 자리 — 그 칸의 intent 틴트로 물들여 "여기에 꽂힌다"를 미리 보여준다 */
function EmptyHint({
  Icon,
  tint,
  iconColor,
  children,
}: {
  Icon: LucideIcon;
  tint: string;
  iconColor: string;
  children: ReactNode;
}) {
  return (
    <div
      className={cn(
        "flex min-h-[96px] flex-1 flex-col items-center justify-center gap-1.5 rounded-xl border border-dashed px-4 text-center text-[12px] leading-relaxed text-ink-500",
        tint,
      )}
    >
      <Icon className={cn("size-4 opacity-60", iconColor)} strokeWidth={2.2} aria-hidden />
      {children}
    </div>
  );
}

const MAX_ROWS = 4;

function BoardTodos({ items, now }: { items: ResolvedItem[]; now: number }) {
  const { isTodoDone, toggleTodo } = usePersona();
  const rows = items.flatMap((item) =>
    item.instances
      .map((inst, idx) => ({ item, inst, idx }))
      .filter(({ inst }) => inst.intentType === "todo" && !inst.done),
  );

  return (
    <BoardCard
      Icon={ListChecks}
      iconBg="bg-butter-100"
      iconColor="text-butter-400"
      title="할 일"
      count={rows.length}
    >
      {rows.length === 0 ? (
        <EmptyHint Icon={ListChecks} tint="border-butter-100 bg-butter-50/50" iconColor="text-butter-400">
          보내면 여기에 할 일이 생겨요
        </EmptyHint>
      ) : (
        <ul className="space-y-1">
          <AnimatePresence initial={false}>
            {rows.slice(0, MAX_ROWS).map(({ item, inst, idx }) => {
              const checked = isTodoDone(item.slug, idx, inst.done ?? false);
              const label = inst.payload?.title ?? inst.label ?? item.title;
              return (
                <motion.li
                  key={`${item.slug}:${idx}`}
                  layout
                  initial={{ opacity: 0, x: -24, scale: 0.97 }}
                  animate={{ opacity: 1, x: 0, scale: 1 }}
                  transition={{ type: "spring", duration: 0.5, bounce: 0.28 }}
                  className="flex items-center gap-2.5 rounded-xl bg-butter-50/70 px-3 py-2"
                >
                  <button
                    role="checkbox"
                    aria-checked={checked}
                    aria-label={`${label} ${checked ? "완료됨" : "미완료"}`}
                    onClick={() => toggleTodo(item.slug, idx, inst.done ?? false)}
                    className={cn(
                      "relative flex size-[18px] flex-none items-center justify-center rounded-md border-[1.5px] transition-colors",
                      "after:absolute after:-inset-2 after:content-['']",
                      checked
                        ? "border-butter-400 bg-butter-400"
                        : "border-butter-400 bg-surface",
                    )}
                  >
                    {checked && (
                      <Check className="size-3 text-white" strokeWidth={3.5} aria-hidden />
                    )}
                  </button>
                  <span
                    className={cn(
                      "min-w-0 flex-1 truncate text-[13px] font-semibold",
                      checked && "text-ink-500 line-through opacity-65",
                    )}
                  >
                    {label}
                  </span>
                  {inst.dueAt !== undefined && !checked && (
                    <span className="flex-none rounded-full bg-butter-100 px-2 py-0.5 text-[10.5px] font-bold text-[#8A6410] tnum">
                      {dday(inst.dueAt, now)}
                    </span>
                  )}
                </motion.li>
              );
            })}
          </AnimatePresence>
          {rows.length > MAX_ROWS && (
            <li className="px-3 pt-1 text-[11.5px] font-medium text-ink-300">
              외 {rows.length - MAX_ROWS}개
            </li>
          )}
        </ul>
      )}
    </BoardCard>
  );
}

function BoardCalendar({
  items,
  now,
  personaSlug,
}: {
  items: ResolvedItem[];
  now: number;
  personaSlug: string;
}) {
  const { year, month } = kstParts(now);
  const entries = useMemo(
    () => calendarEntries(items, year, month, ["schedule", "deadline"]),
    [items, year, month],
  );
  const count = [...entries.values()].reduce((n, list) => n + list.length, 0);

  return (
    <BoardCard
      Icon={Calendar}
      iconBg="bg-sky-100"
      iconColor="text-sky-400"
      title={`${month}월`}
      count={count}
    >
      <MiniCalendar
        now={now}
        entries={entries}
        hrefFor={(slug) => `/p/${personaSlug}/items/${slug}`}
        dense
      />
      {count === 0 && (
        <p className="mt-auto pt-2 text-center text-[11.5px] text-ink-300">
          일정과 마감이 점으로 찍혀요. 날짜를 누르면 자세히 보여요
        </p>
      )}
    </BoardCard>
  );
}

function BoardKnowledge({
  items,
  personaSlug,
}: {
  items: ResolvedItem[];
  personaSlug: string;
}) {
  const rows = items.flatMap((item) =>
    item.instances
      .filter((inst) => inst.intentType === "knowledge")
      .map((inst, i) => ({
        key: `${item.slug}-k${i}`,
        slug: item.slug,
        title: item.title,
        domain: domainOf(item.url),
      })),
  );

  return (
    <BoardCard
      Icon={BookOpen}
      iconBg="bg-mint-100"
      iconColor="text-mint-400"
      title="지식"
      count={rows.length}
    >
      {rows.length === 0 ? (
        <EmptyHint Icon={BookOpen} tint="border-mint-100 bg-mint-100/30" iconColor="text-mint-400">
          링크와 배움은 여기 모여요
        </EmptyHint>
      ) : (
        <ul className="space-y-1">
          <AnimatePresence initial={false}>
            {rows.slice(0, MAX_ROWS).map((row) => (
              <motion.li
                key={row.key}
                layout
                initial={{ opacity: 0, y: 12, scale: 0.97 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                transition={{ type: "spring", duration: 0.5, bounce: 0.28 }}
              >
                <Link
                  href={`/p/${personaSlug}/items/${row.slug}`}
                  className="flex items-center gap-2.5 rounded-xl bg-mint-100/50 px-3 py-2 transition-colors hover:bg-mint-100/80"
                >
                  <BookOpen className="size-3.5 flex-none text-mint-400" aria-hidden />
                  <span className="min-w-0 flex-1 truncate text-[13px] font-semibold">
                    {row.title}
                  </span>
                  {row.domain && (
                    <span className="flex-none text-[10.5px] text-ink-500">{row.domain}</span>
                  )}
                </Link>
              </motion.li>
            ))}
          </AnimatePresence>
          {rows.length > MAX_ROWS && (
            <li className="px-3 pt-1 text-[11.5px] font-medium text-ink-300">
              외 {rows.length - MAX_ROWS}개
            </li>
          )}
        </ul>
      )}
    </BoardCard>
  );
}

const KIND_GLYPH: Record<ResolvedItem["kind"], LucideIcon> = {
  screenshot: Camera,
  url: Link2,
  memo: FileText,
};

/** 기록 — intent 와 무관하게, 보낸 모든 것이 시간순으로 쌓이는 자리 (사라지는 캡처 없음) */
function BoardInbox({
  items,
  liveSlugs,
  now,
  personaSlug,
}: {
  items: ResolvedItem[];
  liveSlugs: Set<string>;
  now: number;
  personaSlug: string;
}) {
  return (
    <BoardCard
      Icon={Inbox}
      iconBg="bg-purple-100"
      iconColor="text-purple-500"
      title="기록"
      count={items.length}
      footer={
        items.length > 0 ? (
          <Link
            href={`/p/${personaSlug}`}
            className="mt-3 inline-flex items-center gap-1 border-t border-ink-100/70 pt-3 text-[12.5px] font-bold text-purple-600 transition-colors hover:text-purple-500"
          >
            홈에 쌓인 모습 보기 <ArrowRight className="size-3.5" aria-hidden />
          </Link>
        ) : undefined
      }
    >
      {items.length === 0 ? (
        <EmptyHint Icon={Inbox} tint="border-purple-100 bg-purple-50/40" iconColor="text-purple-400">
          무엇을 보내든 여기엔 시간순으로 남아요
        </EmptyHint>
      ) : (
        <ul className="space-y-1">
          <AnimatePresence initial={false}>
            {items.slice(0, MAX_ROWS).map((item) => {
              const Glyph = KIND_GLYPH[item.kind];
              const isLive = liveSlugs.has(item.slug);
              return (
                <motion.li
                  key={item.slug}
                  layout
                  initial={{ opacity: 0, y: 12, scale: 0.97 }}
                  animate={{ opacity: 1, y: 0, scale: 1 }}
                  transition={{ type: "spring", duration: 0.5, bounce: 0.28 }}
                >
                  <Link
                    href={`/p/${personaSlug}/items/${item.slug}`}
                    className="flex items-center gap-2.5 rounded-xl bg-bg/80 px-3 py-2 transition-colors hover:bg-bg"
                  >
                    <Glyph className="size-3.5 flex-none text-ink-500" aria-hidden />
                    <span className="min-w-0 flex-1 truncate text-[13px] font-semibold">
                      {item.title}
                    </span>
                    <span
                      className={cn(
                        "flex-none text-[10.5px] font-medium tnum",
                        isLive ? "font-bold text-purple-600" : "text-ink-500",
                      )}
                    >
                      {isLive ? relativeLabel(item.capturedAt, now) : item.source}
                    </span>
                  </Link>
                </motion.li>
              );
            })}
          </AnimatePresence>
          {items.length > MAX_ROWS && (
            <li className="px-3 pt-1 text-[11.5px] font-medium text-ink-300">
              외 {items.length - MAX_ROWS}개
            </li>
          )}
        </ul>
      )}
    </BoardCard>
  );
}
