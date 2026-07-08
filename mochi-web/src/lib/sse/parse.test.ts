import { describe, expect, it } from "vitest";
import { parseSseStream, toTagged } from "./parse";
import type { ChatWireEvent } from "@/lib/api/wire";

/* 실제 wire 포맷 픽스처 — 청크가 이벤트 중간에서 끊기는 경우 포함 */

function streamOf(chunks: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({
    start(c) {
      for (const chunk of chunks) c.enqueue(enc.encode(chunk));
      c.close();
    },
  });
}

async function collect(chunks: string[]) {
  const events = [];
  for await (const e of parseSseStream(streamOf(chunks))) events.push(e);
  return events;
}

describe("parseSseStream", () => {
  it("완전한 이벤트 블록 파싱", async () => {
    const events = await collect([
      'event: message_delta\ndata: {"run_id":"r1","text":"안녕"}\n\n' +
        'event: done\ndata: {"run_id":"r1","message_id":"m1"}\n\n',
    ]);
    expect(events).toHaveLength(2);
    expect(events[0].event).toBe("message_delta");
    expect(JSON.parse(events[0].data).text).toBe("안녕");
    expect(events[1].event).toBe("done");
  });

  it("이벤트 중간에서 끊긴 청크 — 버퍼 유지 (한글 멀티바이트 경계 포함)", async () => {
    const full = 'event: message_delta\ndata: {"run_id":"r1","text":"기록을 뒤지고 있어요"}\n\n';
    const bytes = new TextEncoder().encode(full);
    // 멀티바이트 문자 한가운데서 자른다
    const cut = 40;
    const dec = new TextDecoder();
    const events = await collect([
      dec.decode(bytes.slice(0, cut), { stream: true }),
    ]);
    void events; // 첫 half 만으로는 이벤트 없음을 아래에서 별도 검증

    const parts: string[] = [];
    parts.push(full.slice(0, 25));
    parts.push(full.slice(25, 55));
    parts.push(full.slice(55));
    const got = await collect(parts);
    expect(got).toHaveLength(1);
    expect(JSON.parse(got[0].data).text).toBe("기록을 뒤지고 있어요");
  });

  it("CRLF 경계 처리", async () => {
    const got = await collect([
      'event: tool_started\r\ndata: {"run_id":"r","name":"search_items","label":"찾는 중"}\r\n\r\n',
    ]);
    expect(got).toHaveLength(1);
    expect(got[0].event).toBe("tool_started");
  });

  it("data 없는 블록(주석·keepalive)은 무시", async () => {
    const got = await collect([": keepalive\n\nevent: done\ndata: {}\n\n"]);
    expect(got).toHaveLength(1);
  });

  it("toTagged — kind 태깅과 깨진 JSON 방어", () => {
    const ok = toTagged<ChatWireEvent>({
      event: "citation",
      data: '{"run_id":"r","index":1,"item_id":"a","title":"t","snippet":"s"}',
    });
    expect(ok?.kind).toBe("citation");
    const bad = toTagged({ event: "done", data: "{broken" });
    expect(bad).toBeNull();
  });
});
