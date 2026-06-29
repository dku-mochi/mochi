"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import Image from "next/image";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowRight, Loader2, Sparkles, Type, Link2, ImageIcon, CornerDownLeft } from "lucide-react";
import { Section, GlassCard, BehaviorMark, PillButton } from "@/components/ui";
import { cn } from "@/lib/cn";
import type { AnalysisResult, AnalyzeStage, IntentType } from "@/lib/types";

/* ─────────────────────────────────────────────────────────────
   LiveProof — "직접 넣어보세요" 라이브 증명 (센터피스).
   입력(텍스트/링크/이미지) → POST /api/analyze → SSE 스트림을 직접
   ReadableStream reader 로 파싱해 단계 진행을 보여주고, 최종
   AnalysisResult 를 카드로 펼친다. "이건 목업이 아니라 실제 AI".
   ───────────────────────────────────────────────────────────── */

type Channel = "text" | "url" | "image";

const TABS: { key: Channel; label: string; Icon: typeof Type }[] = [
  { key: "text", label: "텍스트", Icon: Type },
  { key: "url", label: "링크", Icon: Link2 },
  { key: "image", label: "이미지", Icon: ImageIcon },
];

const TEXT_EXAMPLES = [
  "다음주 수요일 3시 디자인 회의, 회의록 미리 정리해두기",
  "학자금 이자 6/19까지 납부",
  "DNS가 계층 구조로 질의를 위임하는 방식 정리",
];

const URL_EXAMPLES = [
  "https://youtube.com/watch?v=dQw4w9WgXcQ",
  "https://news.hada.io/topic?id=12345",
];

/* SSE 단계 → 사람 카피 + 모찌 포즈. failed/analyzed 는 별도 처리. */
const STAGE_COPY: Record<Exclude<AnalyzeStage, "failed" | "analyzed">, { line: string; pose: string }> = {
  ingested: { line: "받았어요", pose: "peek" },
  normalized: { line: "내용을 펼쳐 읽는 중", pose: "question" },
  analyzing: { line: "어떤 기억인지 가늠하는 중", pose: "chat" },
};

const STAGE_ORDER: AnalyzeStage[] = ["ingested", "normalized", "analyzing", "analyzed"];

interface StreamState {
  phase: "idle" | "streaming" | "done" | "error";
  stage: AnalyzeStage | null;
  result: AnalysisResult | null;
  error: string | null;
}

const IDLE: StreamState = { phase: "idle", stage: null, result: null, error: null };

export function LiveProof() {
  const reduced = useReducedMotion();
  const [tab, setTab] = useState<Channel>("text");
  const [text, setText] = useState("");
  const [url, setUrl] = useState("");
  const [state, setState] = useState<StreamState>(IDLE);
  const abortRef = useRef<AbortController | null>(null);

  const examples = tab === "text" ? TEXT_EXAMPLES : tab === "url" ? URL_EXAMPLES : [];
  const busy = state.phase === "streaming";

  const canSubmit = useMemo(() => {
    if (busy) return false;
    if (tab === "text") return text.trim().length > 0;
    if (tab === "url") return url.trim().length > 0;
    return false; // image 탭은 준비 중
  }, [busy, tab, text, url]);

  const run = useCallback(async () => {
    const payload =
      tab === "text"
        ? { channel: "web", text: text.trim() }
        : { channel: "web", url: url.trim() };

    abortRef.current?.abort();
    const ac = new AbortController();
    abortRef.current = ac;
    setState({ phase: "streaming", stage: null, result: null, error: null });

    let res: Response;
    try {
      res = await fetch("/api/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        signal: ac.signal,
      });
    } catch {
      setState({ phase: "error", stage: null, result: null, error: "지금은 연결이 닿지 않아요. 잠시 후 다시 시도해 주세요." });
      return;
    }

    if (res.status === 429) {
      setState({ phase: "error", stage: null, result: null, error: "잠깐만요, 너무 빨라요. 잠시 후 다시 넣어주세요." });
      return;
    }
    if (!res.ok || !res.body) {
      let msg = "분석을 시작하지 못했어요.";
      try {
        const j = (await res.json()) as { error?: string };
        if (j.error) msg = j.error;
      } catch {
        /* body 없음 — 기본 메시지 유지 */
      }
      setState({ phase: "error", stage: null, result: null, error: msg });
      return;
    }

    // ── SSE 파싱: data: <JSON>\n\n ──────────────────────────────
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });

        let sep: number;
        while ((sep = buf.indexOf("\n\n")) !== -1) {
          const frame = buf.slice(0, sep);
          buf = buf.slice(sep + 2);
          const line = frame.split("\n").find((l) => l.startsWith("data:"));
          if (!line) continue;
          const json = line.slice(5).trim();
          if (!json) continue;
          let evt: { stage: AnalyzeStage; result?: AnalysisResult; error?: string };
          try {
            evt = JSON.parse(json);
          } catch {
            continue;
          }
          if (evt.error || evt.stage === "failed") {
            setState({ phase: "error", stage: "failed", result: null, error: evt.error ?? "분석 중에 문제가 생겼어요." });
            return;
          }
          if (evt.stage === "analyzed" && evt.result) {
            setState({ phase: "done", stage: "analyzed", result: evt.result, error: null });
          } else {
            setState((s) => (s.phase === "streaming" ? { ...s, stage: evt.stage } : s));
          }
        }
      }
    } catch {
      if (ac.signal.aborted) return;
      setState((s) =>
        s.phase === "done" ? s : { phase: "error", stage: null, result: null, error: "스트림이 중간에 끊겼어요." },
      );
      return;
    }

    // 스트림이 analyzed 없이 닫힌 경우 방어.
    setState((s) => (s.phase === "done" ? s : { ...s, phase: "error", error: "결과를 받지 못했어요." }));
  }, [tab, text, url]);

  const reset = useCallback(() => {
    abortRef.current?.abort();
    setState(IDLE);
  }, []);

  return (
    <Section
      id="live"
      eyebrow={{ tint: "purple", label: "Live" }}
      title={<>지금, 직접 한 줄 넣어보세요</>}
      lead="아래 칸은 데모가 아니라 실제 모찌 백엔드로 흘러갑니다. 넣는 순간 무엇으로 남길지 직접 가늠해요."
    >
      <div className="grid gap-5 lg:grid-cols-[1.05fr_0.95fr]">
        {/* ── 입력 패널 ─────────────────────────────────────── */}
        <GlassCard className="p-5 sm:p-6">
          {/* 세그먼트 탭 */}
          <div className="flex gap-1 rounded-full bg-black/[0.04] p-1">
            {TABS.map(({ key, label, Icon }) => {
              const active = tab === key;
              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => {
                    setTab(key);
                    if (state.phase !== "streaming") setState(IDLE);
                  }}
                  className={cn(
                    "relative flex flex-1 items-center justify-center gap-1.5 rounded-full px-3 py-2 text-sm font-bold tracking-tight",
                    "transition-colors duration-150",
                    active ? "text-ink-900" : "text-ink-300 hover:text-ink-500",
                  )}
                >
                  {active && (
                    <motion.span
                      layoutId="live-tab"
                      transition={reduced ? { duration: 0 } : { type: "spring", stiffness: 420, damping: 34 }}
                      className="absolute inset-0 rounded-full bg-white shadow-card"
                    />
                  )}
                  <span className="relative z-10 inline-flex items-center gap-1.5">
                    <Icon className="h-4 w-4" strokeWidth={2.2} />
                    {label}
                  </span>
                </button>
              );
            })}
          </div>

          {/* 입력 본문 */}
          <div className="mt-4">
            {tab === "text" && (
              <textarea
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder="놓치기 쉬운 한 줄을 넣어보세요. 예) 다음주 수요일 3시 미팅"
                rows={4}
                disabled={busy}
                maxLength={2000}
                onKeyDown={(e) => {
                  if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && canSubmit) run();
                }}
                className={cn(
                  "w-full resize-none rounded-md border border-black/5 bg-white/70 px-4 py-3.5",
                  "text-base leading-relaxed text-ink-900 placeholder:text-ink-300",
                  "outline-none transition-shadow focus:ring-2 focus:ring-purple-400/50",
                  "disabled:opacity-60",
                )}
              />
            )}

            {tab === "url" && (
              <input
                type="url"
                inputMode="url"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder="https://… 링크를 붙여넣어 보세요"
                disabled={busy}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && canSubmit) run();
                }}
                className={cn(
                  "w-full rounded-md border border-black/5 bg-white/70 px-4 py-3.5",
                  "text-base text-ink-900 placeholder:text-ink-300",
                  "outline-none transition-shadow focus:ring-2 focus:ring-purple-400/50",
                  "disabled:opacity-60",
                )}
              />
            )}

            {tab === "image" && (
              <div className="flex flex-col items-center gap-3 rounded-md border border-dashed border-black/10 bg-white/40 px-4 py-10 text-center">
                <ImageIcon className="h-6 w-6 text-ink-300" strokeWidth={1.8} />
                <p className="text-sm font-semibold text-ink-500">이미지 분석은 곧 열려요</p>
                <p className="max-w-xs text-xs leading-relaxed text-ink-300">
                  앱에서는 스크린샷이 바로 분석됩니다. 웹 데모에선 우선 텍스트와 링크로 직접 확인해 보세요.
                </p>
              </div>
            )}
          </div>

          {/* 예시 칩 */}
          {examples.length > 0 && (
            <div className="mt-4 flex flex-wrap gap-2">
              {examples.map((ex) => (
                <button
                  key={ex}
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    if (tab === "text") setText(ex);
                    else setUrl(ex);
                    if (state.phase !== "streaming") setState(IDLE);
                  }}
                  className={cn(
                    "max-w-full truncate rounded-full border border-black/5 bg-white/60 px-3 py-1.5",
                    "text-xs font-medium text-ink-500 backdrop-blur-md",
                    "transition-colors hover:bg-white hover:text-ink-900 disabled:opacity-50",
                  )}
                >
                  {ex}
                </button>
              ))}
            </div>
          )}

          {/* 액션 */}
          <div className="mt-5 flex items-center justify-between gap-3">
            <span className="text-xs text-ink-300">
              {tab === "image" ? "텍스트·링크 탭에서 시작해 보세요" : "⌘/Ctrl + Enter 로도 보낼 수 있어요"}
            </span>
            <PillButton onClick={run} disabled={!canSubmit}>
              {busy ? (
                <>
                  <Loader2 className="h-4 w-4 animate-spin" strokeWidth={2.4} />
                  분석 중
                </>
              ) : (
                <>
                  <CornerDownLeft className="h-4 w-4" strokeWidth={2.4} />
                  넣어보기
                </>
              )}
            </PillButton>
          </div>
        </GlassCard>

        {/* ── 결과 패널 ─────────────────────────────────────── */}
        <GlassCard className="relative min-h-[20rem] overflow-hidden p-5 sm:p-6">
          <AnimatePresence mode="wait" initial={false}>
            {state.phase === "idle" && (
              <ResultIdle key="idle" reduced={!!reduced} />
            )}
            {state.phase === "streaming" && (
              <ResultStreaming key="streaming" stage={state.stage} reduced={!!reduced} />
            )}
            {state.phase === "error" && (
              <ResultError key="error" message={state.error ?? "문제가 생겼어요."} onRetry={reset} reduced={!!reduced} />
            )}
            {state.phase === "done" && state.result && (
              <ResultDone key="done" result={state.result} onReset={reset} reduced={!!reduced} />
            )}
          </AnimatePresence>
        </GlassCard>
      </div>
    </Section>
  );
}

/* ── 패널: 대기 ───────────────────────────────────────────── */
function ResultIdle({ reduced }: { reduced: boolean }) {
  return (
    <motion.div
      initial={reduced ? false : { opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="flex h-full flex-col items-center justify-center gap-4 text-center"
    >
      <Image
        src="/mochi/mochi-hello.png"
        alt=""
        width={104}
        height={104}
        aria-hidden
        draggable={false}
        className="select-none object-contain"
      />
      <p className="max-w-[15rem] text-sm leading-relaxed text-ink-500">
        넣는 순간, 일정인지 할 일인지 지식인지 모찌가 가늠해서 여기 펼쳐요.
      </p>
    </motion.div>
  );
}

/* ── 패널: 진행 (단계 타임라인 + 모찌) ───────────────────────── */
function ResultStreaming({ stage, reduced }: { stage: AnalyzeStage | null; reduced: boolean }) {
  const activeIdx = stage ? STAGE_ORDER.indexOf(stage) : 0;
  const current = (stage && stage !== "analyzed" && stage !== "failed" ? stage : "ingested") as keyof typeof STAGE_COPY;
  const pose = STAGE_COPY[current]?.pose ?? "peek";

  return (
    <motion.div
      initial={reduced ? false : { opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="flex h-full flex-col items-center justify-center gap-5 text-center"
    >
      <div className="relative">
        <motion.span
          aria-hidden
          className="absolute inset-0 rounded-full bg-purple-100"
          animate={reduced ? {} : { scale: [1, 1.18, 1], opacity: [0.7, 0.3, 0.7] }}
          transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
        />
        <Image
          src={`/mochi/mochi-${pose}.png`}
          alt=""
          width={96}
          height={96}
          aria-hidden
          draggable={false}
          className="relative select-none object-contain"
        />
      </div>

      {/* 단계 타임라인 */}
      <ol className="flex flex-col gap-2.5">
        {(["ingested", "normalized", "analyzing"] as const).map((s) => {
          const idx = STAGE_ORDER.indexOf(s);
          const done = idx < activeIdx;
          const isCurrent = idx === activeIdx;
          return (
            <li key={s} className="flex items-center gap-2.5">
              <span
                className={cn(
                  "flex h-5 w-5 items-center justify-center rounded-full transition-colors",
                  done && "bg-mint-400 text-white",
                  isCurrent && "bg-purple-500 text-white",
                  !done && !isCurrent && "bg-black/[0.06] text-ink-300",
                )}
              >
                {isCurrent ? (
                  <Loader2 className="h-3 w-3 animate-spin" strokeWidth={3} />
                ) : (
                  <span className={cn("h-1.5 w-1.5 rounded-full", done ? "bg-white" : "bg-current")} />
                )}
              </span>
              <span
                className={cn(
                  "text-sm font-semibold tracking-tight",
                  isCurrent ? "text-ink-900" : done ? "text-ink-500" : "text-ink-300",
                )}
              >
                {STAGE_COPY[s].line}
              </span>
            </li>
          );
        })}
      </ol>
    </motion.div>
  );
}

/* ── 패널: 에러 ───────────────────────────────────────────── */
function ResultError({ message, onRetry, reduced }: { message: string; onRetry: () => void; reduced: boolean }) {
  return (
    <motion.div
      initial={reduced ? false : { opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="flex h-full flex-col items-center justify-center gap-4 text-center"
    >
      <Image
        src="/mochi/mochi-question.png"
        alt=""
        width={88}
        height={88}
        aria-hidden
        draggable={false}
        className="select-none object-contain opacity-90"
      />
      <p className="max-w-[16rem] text-sm leading-relaxed text-ink-500">{message}</p>
      <PillButton variant="ghost" onClick={onRetry}>
        다시 시도
      </PillButton>
    </motion.div>
  );
}

/* ── 패널: 결과 카드 ──────────────────────────────────────── */
function ResultDone({ result, onReset, reduced }: { result: AnalysisResult; onReset: () => void; reduced: boolean }) {
  const intents: IntentType[] = result.intents.length > 0 ? result.intents : ["memo"];
  const stagger = reduced ? {} : { transition: { staggerChildren: 0.06, delayChildren: 0.04 } };
  const item = reduced
    ? { hidden: {}, show: {} }
    : { hidden: { opacity: 0, y: 8 }, show: { opacity: 1, y: 0 } };

  return (
    <motion.div
      key="done"
      initial={reduced ? false : { opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0 }}
      className="flex h-full flex-col"
    >
      <motion.div variants={{ show: stagger }} initial="hidden" animate="show" className="flex flex-1 flex-col">
        {/* "실제 AI" 인장 */}
        <motion.div variants={item} className="mb-3 inline-flex items-center gap-1.5 self-start rounded-full bg-purple-100 px-2.5 py-1 text-xs font-bold text-purple-600">
          <Sparkles className="h-3.5 w-3.5" strokeWidth={2.4} />
          방금 그건 목업이 아니라 실제로 도는 AI예요
        </motion.div>

        {/* summary */}
        <motion.p variants={item} className="text-pretty text-lg font-bold leading-snug tracking-tight text-ink-900">
          {result.summary}
        </motion.p>

        {/* category */}
        {result.category && (
          <motion.p variants={item} className="mt-1.5 text-sm font-medium text-ink-500">
            {result.category}
            {result.needsReview ? " · 확인이 필요해요" : ""}
          </motion.p>
        )}

        {/* BehaviorMark — 라벨 없이 행동의 형태로 */}
        <motion.div variants={item} className="mt-5 flex items-center gap-2">
          {intents.map((it) => (
            <BehaviorMark key={it} intent={it} size="md" />
          ))}
          <span className="ml-1 text-xs text-ink-300">이렇게 남겨둘게요</span>
        </motion.div>

        {/* entities */}
        {result.entities.length > 0 && (
          <motion.div variants={item} className="mt-4 flex flex-wrap gap-1.5">
            {result.entities.map((e, i) => (
              <span
                key={`${e.type}-${e.value}-${i}`}
                className="inline-flex items-center gap-1 rounded-full border border-black/5 bg-white/70 px-2.5 py-1 text-xs font-medium text-ink-500"
              >
                <span className="text-ink-300">{e.type}</span>
                <span className="text-ink-900">{e.value}</span>
              </span>
            ))}
          </motion.div>
        )}

        <div className="flex-1" />

        {/* 타임머신 훅 + 다시 */}
        <motion.div variants={item} className="mt-6 flex items-center justify-between gap-3 border-t border-black/5 pt-4">
          <a
            href="#recall"
            className="group inline-flex items-center gap-1.5 text-sm font-bold tracking-tight text-purple-600 transition-colors hover:text-purple-500"
          >
            3주 뒤로
            <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" strokeWidth={2.6} />
          </a>
          <button
            type="button"
            onClick={onReset}
            className="text-sm font-medium text-ink-300 transition-colors hover:text-ink-500"
          >
            다른 것 넣기
          </button>
        </motion.div>
      </motion.div>
    </motion.div>
  );
}
