import { Fragment, type ReactNode } from "react";
import type { ChatCitation } from "@/lib/hooks/useChatStream";

/*
 * 채팅 본문 초소형 렌더러 — 문단 / 불릿·번호 리스트 / **굵게** / 근거 배지.
 * 근거 마커 2종을 iOS ChatMarkup 과 동일 정책으로 받는다:
 *  - 폴백 대본의 `[n]`
 *  - 라이브 본문의 `【item:uuid】` (작은 모델이 흘리는 반각 `[item:uuid]` 도 수용,
 *    매칭 citation 없으면 숨김 — done 후 재렌더에서 뱃지가 나타난다)
 * 스트리밍 중에는 꼬리의 미완성 마커·홀수 `**` 를 잘라 원문 조각 노출을 막는다.
 */

// iOS ChatMarkup.marker 와 동일 — uuid 36자 제약이라 일반 본문 대괄호와의 오탐 없음
const MARKER_SOURCE = String.raw`[【[]item:([0-9a-fA-F-]{36})[】\]]`;

export function trimStreamingTail(text: string): string {
  // 전각 여는 괄호는 그 자체로 마커 확정 — 닫히지 않았으면 꼬리를 자른다
  const fullOpen = text.lastIndexOf("【");
  if (fullOpen !== -1 && !text.slice(fullOpen).includes("】")) {
    text = text.slice(0, fullOpen);
  }
  // 반각은 `[item:` 프리픽스가 보일 때만 (폴백 `[n]` 배지와의 오탐 방지)
  const halfTail = text.search(/\[item:[0-9a-fA-F-]{0,36}$/);
  if (halfTail !== -1) text = text.slice(0, halfTail);
  // 짝이 안 맞는 마지막 ** 이후
  const bolds = text.split("**").length - 1;
  if (bolds % 2 === 1) text = text.slice(0, text.lastIndexOf("**"));
  return text;
}

function badge(index: number, key: string): ReactNode {
  return (
    <sup
      key={key}
      className="ml-0.5 inline-flex size-[15px] translate-y-[-1px] items-center justify-center rounded-full bg-purple-100 text-[9.5px] font-bold text-purple-600"
    >
      {index}
    </sup>
  );
}

function inline(
  text: string,
  keyBase: string,
  indexById: Map<string, number>,
): ReactNode[] {
  const out: ReactNode[] = [];
  // **bold** / [n] / 【item:uuid】 를 함께 스캔
  const re = new RegExp(String.raw`\*\*(.+?)\*\*|\[(\d+)\]|${MARKER_SOURCE}`, "g");
  let last = 0;
  let m: RegExpExecArray | null;
  let k = 0;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1] !== undefined) {
      out.push(
        <strong key={`${keyBase}-b${k++}`} className="font-bold">
          {m[1]}
        </strong>,
      );
    } else if (m[2] !== undefined) {
      out.push(badge(Number(m[2]), `${keyBase}-c${k++}`));
    } else {
      const index = indexById.get(m[3].toLowerCase());
      // 매칭 citation 이 아직 없으면 마커를 숨긴다 (iOS 와 동일)
      if (index !== undefined) out.push(badge(index, `${keyBase}-c${k++}`));
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function ChatMarkup({
  text,
  citations = [],
  streaming = false,
}: {
  text: string;
  citations?: ChatCitation[];
  streaming?: boolean;
}) {
  const indexById = new Map(citations.map((c) => [c.itemId.toLowerCase(), c.index]));
  const processed = streaming ? trimStreamingTail(text) : text;
  const blocks = processed.split(/\n\n+/);
  return (
    <div className="space-y-3">
      {blocks.map((block, bi) => {
        const lines = block.split("\n").filter((l) => l.length > 0);
        const isList = lines.length > 0 && lines.every((l) => /^\s*(-\s|\*\s|\d+\.\s)/.test(l));
        if (isList) {
          // 번호 리스트는 <ol> — 절차·우선순위의 순서 의미를 접근성 트리에 보존
          const ordered = /^\s*\d+\.\s/.test(lines[0]);
          const List = ordered ? "ol" : "ul";
          return (
            <List key={bi} className="space-y-1.5 pl-1">
              {lines.map((l, li) => (
                <li key={li} className="flex gap-2 text-[14.5px] leading-relaxed">
                  {ordered ? (
                    <span className="w-4 flex-none text-right font-bold text-purple-400 tnum" aria-hidden>
                      {li + 1}
                    </span>
                  ) : (
                    <span className="mt-[9px] size-1 flex-none rounded-full bg-purple-400" aria-hidden />
                  )}
                  <span>
                    {inline(l.replace(/^\s*(-\s|\*\s|\d+\.\s)/, ""), `${bi}-${li}`, indexById)}
                  </span>
                </li>
              ))}
            </List>
          );
        }
        return (
          <p key={bi} className="text-[14.5px] leading-relaxed [text-wrap:pretty]">
            {lines.map((l, li) => (
              <Fragment key={li}>
                {li > 0 && <br />}
                {inline(l, `${bi}-${li}`, indexById)}
              </Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}
