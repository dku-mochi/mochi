import { Fragment, type ReactNode } from "react";
import type { ChatCitation } from "@/lib/hooks/useChatStream";

/*
 * iOS ChatMarkup 과 같은 줄 단위 블록 렌더러.
 * 문단·헤딩·혼합 리스트·인용·구분선·표와 인라인 굵게/citation 을 처리한다.
 */

const MARKER_SOURCE = String.raw`[【[]item:([0-9a-fA-F-]{8,36})[】\]]`;

export function trimStreamingTail(text: string): string {
  const fullOpen = text.lastIndexOf("【");
  if (fullOpen !== -1 && !text.slice(fullOpen).includes("】")) {
    text = text.slice(0, fullOpen);
  }
  const halfTail = text.search(/\[item:[0-9a-fA-F-]{0,36}$/);
  if (halfTail !== -1) text = text.slice(0, halfTail);
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

function citationIndex(marker: string, citations: ChatCitation[]): number | undefined {
  const token = marker.toLowerCase();
  const matches = citations.filter((citation) => {
    const id = citation.itemId.toLowerCase();
    return id === token || id.startsWith(token);
  });
  return matches.length === 1 ? matches[0].index : undefined;
}

function inline(text: string, keyBase: string, citations: ChatCitation[]): ReactNode[] {
  const out: ReactNode[] = [];
  const re = new RegExp(String.raw`\*\*(.+?)\*\*|\[(\d+)\]|${MARKER_SOURCE}`, "g");
  let last = 0;
  let match: RegExpExecArray | null;
  let key = 0;
  while ((match = re.exec(text)) !== null) {
    if (match.index > last) out.push(text.slice(last, match.index));
    if (match[1] !== undefined) {
      out.push(
        <strong key={`${keyBase}-b${key++}`} className="font-bold">
          {match[1]}
        </strong>,
      );
    } else if (match[2] !== undefined) {
      out.push(badge(Number(match[2]), `${keyBase}-c${key++}`));
    } else {
      const index = citationIndex(match[3], citations);
      if (index !== undefined) out.push(badge(index, `${keyBase}-c${key++}`));
    }
    last = match.index + match[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

interface ListItem {
  ordinal?: string;
  depth: number;
  text: string;
}

type Block =
  | { kind: "paragraph"; lines: string[] }
  | { kind: "heading"; level: number; text: string }
  | { kind: "list"; items: ListItem[] }
  | { kind: "quote"; lines: string[] }
  | { kind: "divider" }
  | { kind: "table"; header: string[]; rows: string[][] };

const tableCells = (line: string): string[] => {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|").map((cell) => cell.trim());
};

const isTableLine = (line: string): boolean => line.trimStart().startsWith("|");
const isSeparatorLine = (line: string): boolean => {
  const cells = tableCells(line);
  return cells.length > 0 && cells.every((cell) => /^:?-+:?$/.test(cell));
};

export function parseChatBlocks(text: string): Block[] {
  const lines = text.split("\n");
  const blocks: Block[] = [];
  let paragraphs: string[] = [];
  let listItems: ListItem[] = [];
  let quoteLines: string[] = [];

  const flushParagraph = () => {
    if (paragraphs.length > 0) blocks.push({ kind: "paragraph", lines: paragraphs });
    paragraphs = [];
  };
  const flushList = () => {
    if (listItems.length > 0) blocks.push({ kind: "list", items: listItems });
    listItems = [];
  };
  const flushQuote = () => {
    if (quoteLines.length > 0) blocks.push({ kind: "quote", lines: quoteLines });
    quoteLines = [];
  };
  const flushAll = () => {
    flushParagraph();
    flushList();
    flushQuote();
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (isTableLine(line) && index + 1 < lines.length && isSeparatorLine(lines[index + 1])) {
      flushAll();
      const header = tableCells(line);
      const rows: string[][] = [];
      index += 2;
      while (index < lines.length && isTableLine(lines[index])) {
        const row = tableCells(lines[index]);
        rows.push(header.map((_, cell) => row[cell] ?? ""));
        index += 1;
      }
      index -= 1;
      blocks.push({ kind: "table", header, rows });
      continue;
    }
    const heading = /^(#{1,6})\s+(\S.*)$/.exec(line);
    const bullet = /^(\s*)[-*+]\s+(\S.*)$/.exec(line);
    const numbered = /^(\s*)(\d{1,3})[.)]\s+(\S.*)$/.exec(line);
    const quote = /^>\s?(.*)$/.exec(line);

    if (heading) {
      flushAll();
      blocks.push({ kind: "heading", level: heading[1].length, text: heading[2] });
    } else if (/^-{3,}$/.test(line.trim())) {
      flushAll();
      blocks.push({ kind: "divider" });
    } else if (quote) {
      flushParagraph();
      flushList();
      quoteLines.push(quote[1]);
    } else if (bullet) {
      flushParagraph();
      flushQuote();
      listItems.push({ depth: bullet[1].length >= 2 ? 1 : 0, text: bullet[2] });
    } else if (numbered) {
      flushParagraph();
      flushQuote();
      listItems.push({
        ordinal: numbered[2],
        depth: numbered[1].length >= 2 ? 1 : 0,
        text: numbered[3],
      });
    } else if (line.trim().length === 0) {
      flushAll();
    } else {
      flushList();
      flushQuote();
      paragraphs.push(line);
    }
  }
  flushAll();
  return blocks;
}

function inlineLines(lines: string[], keyBase: string, citations: ChatCitation[]): ReactNode {
  return lines.map((line, index) => (
    <Fragment key={index}>
      {index > 0 && <br />}
      {inline(line, `${keyBase}-${index}`, citations)}
    </Fragment>
  ));
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
  const processed = streaming ? trimStreamingTail(text) : text;
  const blocks = parseChatBlocks(processed);

  return (
    <div className="space-y-3">
      {blocks.map((block, blockIndex) => {
        if (block.kind === "paragraph") {
          return (
            <p key={blockIndex} className="text-[14.5px] leading-relaxed [text-wrap:pretty]">
              {inlineLines(block.lines, `${blockIndex}-p`, citations)}
            </p>
          );
        }
        if (block.kind === "heading") {
          const content = inline(block.text, `${blockIndex}-h`, citations);
          return block.level <= 2 ? (
            <h3 key={blockIndex} className="pt-0.5 text-[16.5px] font-bold">
              {content}
            </h3>
          ) : (
            <h4 key={blockIndex} className="pt-0.5 text-[15px] font-bold">
              {content}
            </h4>
          );
        }
        if (block.kind === "list") {
          return (
            <div key={blockIndex} role="list" className="space-y-1.5 py-px">
              {block.items.map((item, itemIndex) => (
                <div
                  key={itemIndex}
                  role="listitem"
                  className={`flex items-start gap-2.5 text-[14.5px] leading-relaxed ${item.depth ? "pl-5" : ""}`}
                >
                  {item.ordinal ? (
                    <span className="w-5 flex-none pt-px text-right text-[13px] font-bold text-purple-500">
                      {item.ordinal}.
                    </span>
                  ) : (
                    <span className="ml-1 mt-[9px] size-[5px] flex-none rounded-full bg-purple-400" aria-hidden />
                  )}
                  <span className="min-w-0 flex-1">
                    {inline(item.text, `${blockIndex}-l${itemIndex}`, citations)}
                  </span>
                </div>
              ))}
            </div>
          );
        }
        if (block.kind === "quote") {
          return (
            <blockquote
              key={blockIndex}
              className="border-l-[3px] border-purple-200 pl-3 text-[14px] leading-relaxed text-ink-500"
            >
              {inlineLines(block.lines, `${blockIndex}-q`, citations)}
            </blockquote>
          );
        }
        if (block.kind === "divider") {
          return <hr key={blockIndex} className="h-0.5 w-11 rounded-full border-0 bg-purple-100" />;
        }
        return (
          <div key={blockIndex} className="overflow-x-auto rounded-xl border border-ink-100">
            <table className="min-w-full border-collapse text-left text-[12.5px]">
              <thead className="bg-purple-50 text-ink-700">
                <tr>
                  {block.header.map((cell, cellIndex) => (
                    <th key={cellIndex} className="border-b border-ink-100 px-3 py-2 font-bold">
                      {inline(cell, `${blockIndex}-th${cellIndex}`, citations)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {block.rows.map((row, rowIndex) => (
                  <tr key={rowIndex} className="border-b border-ink-100 last:border-0">
                    {row.map((cell, cellIndex) => (
                      <td key={cellIndex} className="px-3 py-2 align-top">
                        {inline(cell, `${blockIndex}-tr${rowIndex}-${cellIndex}`, citations)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })}
    </div>
  );
}
