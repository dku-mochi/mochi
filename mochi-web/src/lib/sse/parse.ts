/*
 * SSE 파서 — fetch ReadableStream 용 (POST-as-SSE 라 EventSource 불가).
 * iOS SSEEventParser 와 같은 규칙: 빈 줄 = 이벤트 경계, `event:`/`data:` 필드.
 * 청크가 이벤트 중간에서 끊겨도 안전 (버퍼 유지).
 */

export interface SseEvent {
  event: string;
  data: string;
}

export async function* parseSseStream(
  body: ReadableStream<Uint8Array>,
  signal?: AbortSignal,
): AsyncGenerator<SseEvent> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      if (signal?.aborted) return;
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let boundary: number;
      // 이벤트 경계(빈 줄)까지 자른다 — \n\n 또는 \r\n\r\n
      while ((boundary = buffer.search(/\r?\n\r?\n/)) !== -1) {
        const raw = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, "");
        const evt = parseEventBlock(raw);
        if (evt) yield evt;
      }
    }
    const tail = parseEventBlock(buffer);
    if (tail) yield tail;
  } finally {
    reader.releaseLock();
  }
}

function parseEventBlock(block: string): SseEvent | null {
  let event = "message";
  const data: string[] = [];
  for (const line of block.split(/\r?\n/)) {
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
  }
  if (data.length === 0) return null;
  return { event, data: data.join("\n") };
}

/** `event: <kind>` + `data: <json>` 를 kind 태그 객체로 */
export function toTagged<T extends { kind: string }>(evt: SseEvent): T | null {
  try {
    return { kind: evt.event, ...JSON.parse(evt.data) } as T;
  } catch {
    return null;
  }
}
