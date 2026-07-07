import { Fragment, type ReactNode } from "react";

/*
 * 채팅 본문 초소형 렌더러 — 문단 / 불릿·번호 리스트 / **굵게** / [n] 위첨자 근거 배지.
 * 스트리밍 중 부분 텍스트에도 안전.
 */

function inline(text: string, keyBase: string): ReactNode[] {
  const out: ReactNode[] = [];
  // **bold** 와 [n] 을 함께 스캔
  const re = /\*\*(.+?)\*\*|\[(\d+)\]/g;
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
    } else {
      out.push(
        <sup
          key={`${keyBase}-c${k++}`}
          className="ml-0.5 inline-flex size-[15px] translate-y-[-1px] items-center justify-center rounded-full bg-purple-100 text-[9.5px] font-bold text-purple-600"
        >
          {m[2]}
        </sup>,
      );
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function ChatMarkup({ text }: { text: string }) {
  const blocks = text.split(/\n\n+/);
  return (
    <div className="space-y-3">
      {blocks.map((block, bi) => {
        const lines = block.split("\n").filter((l) => l.length > 0);
        const isList = lines.length > 0 && lines.every((l) => /^(-\s|\d+\.\s)/.test(l));
        if (isList) {
          return (
            <ul key={bi} className="space-y-1.5 pl-1">
              {lines.map((l, li) => (
                <li key={li} className="flex gap-2 text-[14.5px] leading-relaxed">
                  <span className="mt-[9px] size-1 flex-none rounded-full bg-purple-400" aria-hidden />
                  <span>{inline(l.replace(/^(-\s|\d+\.\s)/, ""), `${bi}-${li}`)}</span>
                </li>
              ))}
            </ul>
          );
        }
        return (
          <p key={bi} className="text-[14.5px] leading-relaxed [text-wrap:pretty]">
            {lines.map((l, li) => (
              <Fragment key={li}>
                {li > 0 && <br />}
                {inline(l, `${bi}-${li}`)}
              </Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}
