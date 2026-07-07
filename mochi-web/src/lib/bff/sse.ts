import "server-only";

/*
 * 서버 → 클라 SSE 인코딩. 라이브 프록시 패스스루와 폴백 재생이 같은 응답 형태를 쓴다.
 * 클라이언트 단절(req.signal)·스트림 cancel 시 남은 delay/이터레이터를 즉시 정리한다.
 */

export interface OutEvent {
  event: string;
  data: unknown;
  /** 이 이벤트를 내보내기 전 대기 (연출 페이싱) */
  delayMs?: number;
}

const encoder = new TextEncoder();

function encode(e: OutEvent): Uint8Array {
  return encoder.encode(`event: ${e.event}\ndata: ${JSON.stringify(e.data)}\n\n`);
}

/** OutEvent 시퀀스를 페이싱대로 흘리는 SSE Response */
export function sseResponse(
  events: AsyncIterable<OutEvent> | OutEvent[],
  init?: { mode?: "live" | "fallback"; signal?: AbortSignal },
): Response {
  const iterable = Symbol.asyncIterator in events ? events : arrayToAsync(events);
  const iterator = iterable[Symbol.asyncIterator]();

  let stopped = false;
  let wake: (() => void) | null = null;
  const stop = () => {
    stopped = true;
    wake?.();
  };
  init?.signal?.addEventListener("abort", stop, { once: true });

  // abort 시 즉시 깨어나는 취소 가능 sleep
  const sleep = (ms: number) =>
    new Promise<void>((resolve) => {
      const t = setTimeout(() => {
        wake = null;
        resolve();
      }, ms);
      wake = () => {
        clearTimeout(t);
        wake = null;
        resolve();
      };
    });

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        while (!stopped) {
          const { done, value } = await iterator.next();
          if (done || stopped) break;
          if (value.delayMs) {
            await sleep(value.delayMs);
            if (stopped) break;
          }
          controller.enqueue(encode(value));
        }
      } catch {
        // 스트림 소비자가 끊었거나 업스트림 오류 — 조용히 종료
      } finally {
        init?.signal?.removeEventListener("abort", stop);
        try {
          await iterator.return?.(undefined);
        } catch {
          /* iterator 정리 실패 무시 */
        }
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      }
    },
    cancel() {
      stop();
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
      "x-mochi-mode": init?.mode ?? "fallback",
    },
  });
}

async function* arrayToAsync(events: OutEvent[]): AsyncGenerator<OutEvent> {
  for (const e of events) yield e;
}

/** message_delta 용 — 전체 텍스트를 자연스러운 타자 델타로 쪼갠다 */
export function* chunkText(text: string, size = 9): Generator<string> {
  for (let i = 0; i < text.length; i += size) yield text.slice(i, i + size);
}
