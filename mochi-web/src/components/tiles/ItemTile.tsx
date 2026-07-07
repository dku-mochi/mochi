"use client";

import Image from "next/image";
import Link from "next/link";
import { motion, useReducedMotion } from "framer-motion";
import { Link2 } from "lucide-react";
import type { ResolvedItem } from "@/lib/seedRuntime";
import { relativeLabel } from "@/lib/seedRuntime";
import { IntentChip } from "@/components/primitives/IntentChip";

/*
 * iOS SearchGridCard 이식 — 카드 형태가 곧 타입:
 * 스크린샷=풀블리드 이미지+스크림, 링크=퍼플 타일+도메인, 메모=버터 타일+인용 워터마크.
 */

export function domainOf(url?: string): string {
  if (!url) return "";
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function ItemTile({
  item,
  now,
  href,
  showIntent = true,
}: {
  item: ResolvedItem;
  now: number;
  href: string;
  showIntent?: boolean;
}) {
  const reduce = useReducedMotion();
  const time = relativeLabel(item.capturedAt, now);

  return (
    <motion.div
      whileHover={reduce ? undefined : { y: -3 }}
      whileTap={reduce ? undefined : { scale: 0.97 }}
      transition={{ type: "spring", duration: 0.3, bounce: 0 }}
      className="group"
    >
      <Link
        href={href}
        aria-label={`${item.title} — ${time}`}
        className="block overflow-hidden rounded-2xl shadow-card transition-shadow duration-300 group-hover:shadow-card-lift"
      >
        {item.image ? (
          <div className="relative aspect-[2/3]">
            {item.image.width > item.image.height ? (
              /* 가로 이미지 — iOS LocalThumbnail 규칙: fit + 같은 이미지 블러 배경 */
              <>
                <Image
                  src={item.image.file}
                  alt=""
                  fill
                  sizes="260px"
                  className="scale-125 object-cover blur-xl saturate-150"
                  aria-hidden
                />
                <Image
                  src={item.image.file}
                  alt={item.title}
                  fill
                  sizes="(max-width: 768px) 50vw, 260px"
                  className="object-contain px-2"
                />
              </>
            ) : (
              <Image
                src={item.image.file}
                alt={item.title}
                fill
                sizes="(max-width: 768px) 50vw, 260px"
                className="object-cover object-top"
              />
            )}
            <div
              className="absolute inset-0 rounded-2xl ring-1 ring-inset ring-black/10"
              aria-hidden
            />
            <div
              className="absolute inset-x-0 bottom-0 h-[45%] bg-gradient-to-t from-ink-900/75 via-ink-900/30 to-transparent"
              aria-hidden
            />
            {showIntent && (
              <IntentChip
                intent={item.primaryIntent}
                size="sm"
                className="absolute left-2.5 top-2.5 shadow-card"
              />
            )}
            <div className="absolute inset-x-0 bottom-0 p-3.5">
              <p className="line-clamp-2 text-[14.5px] font-bold leading-snug text-white [text-wrap:balance]">
                {item.title}
              </p>
              <p className="mt-1 text-[11.5px] font-medium text-white/75">
                {item.kind === "url" ? domainOf(item.url) : item.source} · {time}
              </p>
            </div>
          </div>
        ) : item.kind === "url" ? (
          <div className="flex aspect-[2/3] flex-col bg-purple-50 p-4 ring-1 ring-inset ring-purple-100">
            <div className="flex items-center justify-between">
              <span className="flex size-10 items-center justify-center rounded-xl bg-surface text-[16px] font-extrabold text-purple-500 shadow-card">
                {domainOf(item.url)[0]?.toUpperCase() ?? (
                  <Link2 className="size-4" />
                )}
              </span>
              {showIntent && <IntentChip intent={item.primaryIntent} size="sm" />}
            </div>
            <p className="mt-4 line-clamp-3 text-[15px] font-bold leading-snug text-ink-900 [text-wrap:balance]">
              {item.title}
            </p>
            {item.text && (
              <p className="mt-2 line-clamp-2 text-[12px] leading-relaxed text-ink-500">
                {item.text}
              </p>
            )}
            <p className="mt-auto truncate pt-3 text-[11.5px] font-medium text-purple-600/80">
              {domainOf(item.url)} · {time}
            </p>
          </div>
        ) : (
          <div className="relative flex aspect-[2/3] flex-col overflow-hidden bg-butter-50 p-4 ring-1 ring-inset ring-butter-100">
            <span
              className="pointer-events-none absolute -right-1 -top-7 font-display text-[88px] leading-none text-butter-400/25"
              aria-hidden
            >
              &ldquo;
            </span>
            {showIntent && (
              <IntentChip intent={item.primaryIntent} size="sm" className="self-start" />
            )}
            <p className="mt-3.5 line-clamp-2 text-[15px] font-bold leading-snug text-ink-900">
              {item.title}
            </p>
            {item.text && (
              <p className="mt-2 line-clamp-4 text-[12.5px] leading-relaxed text-ink-700">
                {item.text}
              </p>
            )}
            <p className="mt-auto pt-3 text-[11.5px] font-medium text-ink-500">
              {item.source} · {time}
            </p>
          </div>
        )}
      </Link>
    </motion.div>
  );
}
