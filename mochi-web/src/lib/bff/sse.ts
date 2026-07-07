import "server-only";

/*
 * 서버 → 클라 SSE 인코딩. 라이브 프록시 패스스루와 폴백 재생이 같은 응답 형태를 쓴다.
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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** OutEvent 시퀀스를 페이싱대로 흘리는 SSE Response */
export function sseResponse(
  events: AsyncIterable<OutEvent> | OutEvent[],
  init?: { mode?: "live" | "fallback" },
): Response {
  const iterable = Symbol.asyncIterator in events ? events : arrayToAsync(events);
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const e of iterable) {
          if (e.delayMs) await sleep(e.delayMs);
          controller.enqueue(encode(e));
        }
      } catch {
        // 스트림 소비자가 끊은 경우 — 조용히 종료
      } finally {
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      }
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
