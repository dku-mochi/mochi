"use client";

import Image from "next/image";
import Link from "next/link";
import {
  ArrowLeft,
  ArrowUpRight,
  Camera,
  Check,
  Link2,
  MapPin,
  ShoppingBag,
  Sparkles,
  Star,
  type LucideIcon,
} from "lucide-react";
import { motion, useReducedMotion } from "framer-motion";
import { usePersona } from "@/components/journey/PersonaProvider";
import {
  findItem,
  relativeLabel,
  koreanDate,
  dday,
  kstParts,
  type ResolvedItem,
} from "@/lib/seedRuntime";
import { RiseIn } from "@/components/primitives/RiseIn";
import { ItemTile, domainOf } from "@/components/tiles/ItemTile";
import { cn } from "@/lib/cn";
import { purchaseSearchFallback } from "@/lib/purchaseSearch";
import { NaverMapPreview } from "./NaverMapPreview";

/*
 * iOS DetailView 이식 — "검수가 아니라 회수".
 * 회수 헤더 → 지금 할 수 있어요 → 장소 → 관련 링크 → 모찌가 정리했어요 → 비슷한 기록.
 */
export function DetailScene({ slug }: { slug: string }) {
  const { persona, items, now } = usePersona();
  const item = findItem(items, slug);
  if (!item) {
    // 세션 오버레이 slug 를 다른 브라우저/탭에서 연 경우 — 정직하게 안내
    return (
      <main className="mx-auto flex max-w-3xl flex-col items-center px-5 py-24 text-center">
        <Image src="/brand/mochi-question.png" alt="" width={84} height={84} className="h-[76px] w-auto" />
        <p className="mt-4 text-[16px] font-bold">이 기록은 보낸 브라우저에만 있어요</p>
        <p className="mt-1.5 text-[13px] leading-relaxed text-ink-500">
          다른 브라우저나 새 세션에서는 보이지 않아요.
        </p>
        <Link
          href={`/p/${persona.slug}`}
          className="mt-5 inline-flex h-10 items-center gap-1.5 rounded-full bg-ink-900 px-5 text-[13.5px] font-bold text-white transition-colors hover:bg-ink-700"
        >
          <ArrowLeft className="size-4" aria-hidden /> 홈으로
        </Link>
      </main>
    );
  }

  const related = (item.relatedSlugs ?? [])
    .map((s) => findItem(items, s))
    .filter((x): x is ResolvedItem => Boolean(x));
  const originalKey = canonicalUrlKey(item.url);
  const references = (item.referenceLinks ?? []).filter(
    (reference) => safeHttpUrl(reference.url) && canonicalUrlKey(reference.url) !== originalKey,
  );

  return (
    <main className="mx-auto max-w-3xl px-5 py-6">
      <RiseIn index={0}>
        <Link
          href={`/p/${persona.slug}`}
          className="inline-flex h-10 items-center gap-1.5 rounded-full text-[14px] font-semibold text-ink-500 transition-colors hover:text-ink-900"
        >
          <ArrowLeft className="size-4" aria-hidden /> 홈으로
        </Link>
      </RiseIn>

      <RiseIn index={1}>
        <DetailHero item={item} />
      </RiseIn>

      <RiseIn index={2}>
        <p className="mt-5 text-[12.5px] font-semibold uppercase tracking-wide text-ink-500">
          {item.category} · {item.source} · {relativeLabel(item.capturedAt, now)}
        </p>
        <h1 className="mt-1.5 font-display text-[26px] leading-snug tracking-head [text-wrap:balance]">
          {item.title}
        </h1>
      </RiseIn>

      <RiseIn index={3}>
        <ActionNow item={item} />
      </RiseIn>

      <RiseIn index={4}>
        {item.place && <PlaceSection place={item.place} />}
      </RiseIn>

      <RiseIn index={5}>
        {references.length > 0 && <ReferenceLinksSection links={references} />}
      </RiseIn>

      <RiseIn index={6}>
        <MochiSummary item={item} />
      </RiseIn>

      {related.length > 0 && (
        <RiseIn index={7}>
          <section aria-label="비슷한 기록" className="mt-8">
            <h2 className="text-[17px] font-extrabold tracking-snug">
              비슷한 기록
            </h2>
            <div className="mt-3 flex gap-3.5 overflow-x-auto pb-2 [&>*]:w-[170px] [&>*]:flex-none">
              {related.map((r) => (
                <ItemTile
                  key={r.slug}
                  item={r}
                  now={now}
                  href={`/p/${persona.slug}/items/${r.slug}`}
                  showIntent={false}
                />
              ))}
            </div>
          </section>
        </RiseIn>
      )}
    </main>
  );
}

/** "~로/으로" 조사 — 마지막 한글 음절의 받침 유무 (ㄹ 받침은 "로") */
function withRo(word: string): string {
  const last = word.trim().at(-1) ?? "";
  const code = last.charCodeAt(0);
  if (code < 0xac00 || code > 0xd7a3) return "로";
  const jong = (code - 0xac00) % 28;
  return jong === 0 || jong === 8 ? "로" : "으로";
}

function safeHttpUrl(value?: string): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function canonicalUrlKey(value?: string): string | undefined {
  const safe = safeHttpUrl(value);
  if (!safe) return undefined;
  const url = new URL(safe);
  url.hash = "";
  url.hostname = url.hostname.toLowerCase();
  url.pathname = url.pathname.replace(/\/$/, "") || "/";
  return url.toString();
}

function DetailHero({ item }: { item: ResolvedItem }) {
  if (item.image) {
    const landscape = item.image.width > item.image.height;
    return (
      <div className="relative mt-4 flex h-[440px] items-center justify-center overflow-hidden rounded-3xl bg-gradient-to-br from-purple-50 via-bg to-cream-100">
        <Image
          src={item.image.file}
          alt={`${item.title} 캡처 원본`}
          width={item.image.width}
          height={item.image.height}
          priority
          unoptimized={item.image.file.startsWith("data:")}
          className={cn(
            "rounded-2xl shadow-card-lift ring-1 ring-black/10",
            landscape ? "h-auto w-[86%]" : "h-[396px] w-auto",
          )}
        />
        <div className="absolute inset-0 rounded-3xl ring-1 ring-inset ring-black/10" aria-hidden />
        <span className="absolute left-4 top-4 inline-flex items-center gap-1.5 rounded-full bg-ink-900/70 px-3 py-1.5 text-[12px] font-semibold text-white backdrop-blur">
          {item.kind === "screenshot" ? (
            <>
              <Camera className="size-3.5" aria-hidden /> 캡처
            </>
          ) : (
            <>
              <Link2 className="size-3.5" aria-hidden />
              {domainOf(item.url) || item.source}
            </>
          )}
        </span>
      </div>
    );
  }
  const isUrl = item.kind === "url";
  return (
    <div
      className={cn(
        "relative mt-4 flex h-[190px] items-end overflow-hidden rounded-3xl p-6",
        isUrl
          ? "bg-gradient-to-br from-purple-100 via-purple-50 to-cream-100"
          : "bg-gradient-to-br from-butter-100 via-butter-50 to-cream-100",
      )}
    >
      <span
        className={cn(
          "pointer-events-none absolute -right-3 -top-12 font-display text-[150px] leading-none",
          isUrl ? "text-purple-200/60" : "text-butter-400/20",
        )}
        aria-hidden
      >
        {isUrl ? "@" : "“"}
      </span>
      <span
        className={cn(
          "inline-flex items-center gap-2 rounded-full bg-surface/85 px-3.5 py-2 text-[13px] font-bold shadow-card backdrop-blur",
          isUrl ? "text-purple-600" : "text-[#8A6410]",
        )}
      >
        {isUrl ? <Link2 className="size-4" aria-hidden /> : null}
        {isUrl ? domainOf(item.url) : `${item.source}${withRo(item.source)} 남긴 기록`}
      </span>
    </div>
  );
}

/** "지금 할 수 있어요" — 분류가 아니라 행동 (할일 체크 / 일정 타일 / 원본 열기) */
function ActionNow({ item }: { item: ResolvedItem }) {
  const { now, isTodoDone, toggleTodo } = usePersona();
  const reduce = useReducedMotion();

  const rows: React.ReactNode[] = [];

  item.instances.forEach((inst, idx) => {
    if (inst.intentType === "todo") {
      const checked = isTodoDone(item.slug, idx, inst.done ?? false);
      const label = inst.payload?.title ?? inst.label ?? item.title;
      rows.push(
        <button
          key={`todo-${idx}`}
          role="checkbox"
          aria-checked={checked}
          onClick={() => toggleTodo(item.slug, idx, inst.done ?? false)}
          className="flex w-full items-center gap-3.5 rounded-2xl p-3 text-left transition-colors hover:bg-bg"
        >
          <span
            className={cn(
              "flex size-6 flex-none items-center justify-center rounded-lg border-[1.5px] transition-colors duration-200",
              checked
                ? "border-butter-400 bg-butter-400"
                : "border-ink-300 bg-surface",
            )}
          >
            <motion.span
              initial={false}
              animate={
                reduce
                  ? { opacity: checked ? 1 : 0 }
                  : { scale: checked ? 1 : 0.25, opacity: checked ? 1 : 0 }
              }
              transition={{ type: "spring", duration: 0.3, bounce: 0 }}
            >
              <Check className="size-4 text-white" strokeWidth={3.5} />
            </motion.span>
          </span>
          <span className="min-w-0 flex-1">
            <span
              className={cn(
                "block text-[15px] font-semibold transition-[color,opacity]",
                checked ? "text-ink-500 line-through opacity-65" : "text-ink-900",
              )}
            >
              {label}
            </span>
            {inst.dueAt !== undefined && (
              <span className="mt-0.5 block text-[12.5px] text-ink-500">
                {koreanDate(inst.dueAt)}까지 · {dday(inst.dueAt, now)}
              </span>
            )}
          </span>
        </button>,
      );
    }
    if (inst.intentType === "schedule" && inst.dueAt !== undefined) {
      const date = kstParts(inst.dueAt);
      rows.push(
        <div key={`sch-${idx}`} className="flex items-center gap-3.5 rounded-2xl p-3">
          <span className="flex size-12 flex-none flex-col items-center justify-center rounded-xl bg-sky-100 leading-none">
            <span className="text-[10px] font-bold text-[#1D5FB8]">
              {date.month}월
            </span>
            <span className="mt-0.5 text-[17px] font-extrabold text-[#1D5FB8] tnum">
              {date.day}
            </span>
          </span>
          <span className="min-w-0 flex-1">
            <span className="block text-[15px] font-semibold text-ink-900">
              {inst.payload?.title ?? inst.label ?? item.title}
            </span>
            <span className="mt-0.5 block text-[12.5px] text-ink-500">
              {koreanDate(inst.dueAt)}
              {inst.payload?.time ? ` · ${inst.payload.time}` : ""} ·{" "}
              {dday(inst.dueAt, now)}
            </span>
          </span>
        </div>,
      );
    }
  });

  const originalUrl = safeHttpUrl(item.url);
  if (originalUrl) {
    rows.push(
      <ActionLinkRow
        key="url"
        href={originalUrl}
        label={sourceActionLabel(originalUrl)}
        subtitle={domainOf(originalUrl)}
        Icon={Link2}
      />,
    );
  }

  const purchaseSearch = purchaseSearchFallback(item);
  if (purchaseSearch) {
    rows.push(
      <ActionLinkRow
        key="purchase-search"
        href={purchaseSearch.url}
        label={purchaseSearch.label}
        subtitle={purchaseSearch.query}
        Icon={ShoppingBag}
      />,
    );
  }

  if (rows.length === 0) return null;
  return (
    <section
      aria-label="지금 할 수 있어요"
      className="mt-6 rounded-3xl border border-ink-100 bg-surface p-2.5 shadow-card"
    >
      <h2 className="px-3 pb-1 pt-2.5 text-[13px] font-bold text-ink-500">
        지금 할 수 있어요
      </h2>
      <div className="divide-y divide-ink-100/70">{rows}</div>
    </section>
  );
}

function ActionLinkRow({
  href,
  label,
  subtitle,
  Icon,
}: {
  href: string;
  label: string;
  subtitle: string;
  Icon: LucideIcon;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="flex items-center gap-3.5 rounded-2xl p-3 transition-colors hover:bg-bg"
    >
      <span className="flex size-12 flex-none items-center justify-center rounded-xl bg-purple-50">
        <Icon className="size-5 text-purple-500" aria-hidden />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block text-[15px] font-semibold text-ink-900">{label}</span>
        <span className="mt-0.5 block truncate text-[12.5px] text-ink-500">
          {subtitle}
        </span>
      </span>
      <ArrowUpRight className="size-4 flex-none text-ink-300" aria-hidden />
    </a>
  );
}

function sourceActionLabel(url: string): string {
  const host = domainOf(url).toLowerCase();
  if (host.includes("youtu")) return "YouTube에서 보기";
  if (host.includes("instagram")) return "Instagram에서 보기";
  if (host === "x.com" || host.includes("twitter")) return "X에서 보기";
  if (host.includes("tiktok")) return "TikTok에서 보기";
  return "원본에서 보기";
}

type ReferenceLink = NonNullable<ResolvedItem["referenceLinks"]>[number];
type Place = NonNullable<ResolvedItem["place"]>;

function referenceStyle(reference: ReferenceLink): {
  name: string;
  tile: string;
  accent: string;
} {
  const { provider } = reference;
  const brands: Record<string, { name: string; tile: string; accent: string }> = {
    oliveyoung: { name: "올리브영", tile: "bg-mint-100", accent: "text-mint-400" },
    naver_map: { name: "네이버 지도", tile: "bg-mint-100", accent: "text-mint-400" },
    naver_shopping: { name: "네이버쇼핑", tile: "bg-mint-100", accent: "text-mint-400" },
    smartstore: { name: "스마트스토어", tile: "bg-mint-100", accent: "text-mint-400" },
    coupang: { name: "쿠팡", tile: "bg-blush-100", accent: "text-blush-400" },
    catchtable: { name: "캐치테이블", tile: "bg-peach-100", accent: "text-peach-400" },
    zigzag: { name: "지그재그", tile: "bg-blush-100", accent: "text-blush-400" },
    musinsa: { name: "무신사", tile: "bg-ink-100", accent: "text-ink-700" },
    "29cm": { name: "29CM", tile: "bg-ink-100", accent: "text-ink-700" },
    wconcept: { name: "W컨셉", tile: "bg-ink-100", accent: "text-ink-700" },
    openmarket: { name: "오픈마켓", tile: "bg-butter-100", accent: "text-[#8A6410]" },
    info: { name: "블로그·아티클", tile: "bg-sky-100", accent: "text-[#1D5FB8]" },
    social: { name: "SNS", tile: "bg-peach-100", accent: "text-peach-400" },
    official: { name: "공식 사이트", tile: "bg-purple-50", accent: "text-purple-500" },
    visible_url: { name: "화면 속 링크", tile: "bg-purple-50", accent: "text-purple-600" },
    original_url: { name: "원본 링크", tile: "bg-purple-50", accent: "text-purple-600" },
  };
  return brands[provider] ?? { name: "관련 링크", tile: "bg-purple-50", accent: "text-purple-500" };
}

function ReferenceFaviconTile({ href, tile }: { href: string; tile: string }) {
  const host = new URL(href).hostname;
  const letter = host.replace(/^www\./, "").charAt(0).toUpperCase() || "L";
  const favicon = `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=64`;
  return (
    <span
      className={cn(
        "relative flex size-[50px] flex-none items-center justify-center overflow-hidden rounded-[14px] border border-black/5 text-[18px] font-extrabold text-purple-600",
        tile,
      )}
      aria-hidden
    >
      {letter}
      {/* eslint-disable-next-line @next/next/no-img-element -- same Google favicon service as iOS FaviconTile */}
      <img
        src={favicon}
        alt=""
        className="absolute size-7 rounded-lg bg-white object-cover"
        onError={(event) => event.currentTarget.remove()}
      />
    </span>
  );
}

function ReferenceLinksSection({ links }: { links: ReferenceLink[] }) {
  return (
    <section aria-label="관련 링크" className="mt-6">
      <h2 className="flex items-center gap-1.5 px-1 text-[14px] font-extrabold tracking-snug">
        <Sparkles className="size-3.5 text-purple-500" aria-hidden /> 관련 링크
      </h2>
      <div className="mt-3 space-y-2.5">
        {links.map((reference) => {
          const href = safeHttpUrl(reference.url)!;
          const style = referenceStyle(reference);
          return (
            <a
              key={href}
              href={href}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-3 rounded-2xl border border-ink-100 bg-surface p-3.5 shadow-card transition-[border-color,transform] hover:-translate-y-0.5 hover:border-purple-200"
            >
              <ReferenceFaviconTile href={href} tile={style.tile} />
              <span className="min-w-0 flex-1">
                <span className="flex flex-wrap items-center gap-1.5">
                  <span className={cn("text-[11px] font-bold", style.accent)}>{style.name}</span>
                  {(reference.usefulness ?? 0) >= 5 && (
                    <span className="rounded-full bg-purple-50 px-2 py-0.5 text-[9.5px] font-bold text-purple-600">
                      딱 맞아요
                    </span>
                  )}
                </span>
                <span className="mt-0.5 block truncate text-[14px] font-semibold text-ink-900">
                  {reference.title || reference.label}
                </span>
                <span className="mt-0.5 flex min-w-0 items-center gap-2 text-[11.5px] text-ink-500">
                  <span className="truncate">{reference.subtitle ?? domainOf(href)}</span>
                  {reference.priceText && (
                    <span className={cn("flex-none font-extrabold", style.accent)}>
                      {reference.priceText}
                    </span>
                  )}
                </span>
              </span>
              <ArrowUpRight className="size-4 flex-none text-ink-300" aria-hidden />
            </a>
          );
        })}
      </div>
    </section>
  );
}

function PlaceSection({ place }: { place: Place }) {
  const mapHref =
    safeHttpUrl(place.mapUrl) ??
    `https://map.naver.com/p/search/${encodeURIComponent(place.name)}`;
  const category = place.category?.split(">").at(-1);
  const address = place.roadAddress ?? place.address;
  const placeImage = trustedPlaceImage(place.imageUrl);

  return (
    <section aria-label="장소" className="mt-6">
      <h2 className="flex items-center gap-1.5 px-1 text-[14px] font-extrabold tracking-snug">
        <MapPin className="size-3.5 text-purple-500" aria-hidden /> 장소
      </h2>
      <div className="mt-3 overflow-hidden rounded-3xl border border-ink-100 bg-surface shadow-card">
        <a
          href={mapHref}
          target="_blank"
          rel="noreferrer"
          aria-label={`네이버 지도에서 ${place.name} 보기`}
          className="relative block h-[168px] overflow-hidden bg-sky-100"
        >
          <NaverMapPreview lat={place.lat} lng={place.lng} />
          {placeImage && (
            // eslint-disable-next-line @next/next/no-img-element -- backend-validated googleusercontent place photo
            <img
              src={placeImage}
              alt=""
              className="absolute bottom-3 left-3 size-16 rounded-2xl border-[3px] border-white object-cover shadow-card-lift"
            />
          )}
          <span className="absolute bottom-3 right-3 inline-flex items-center gap-1 rounded-full bg-surface/90 px-3 py-1.5 text-[10.5px] font-bold text-ink-900 shadow-card backdrop-blur">
            네이버 지도 <ArrowUpRight className="size-3" aria-hidden />
          </span>
        </a>
        <div className="flex items-center gap-3 p-4">
          <span className="min-w-0 flex-1">
            <span className="block truncate text-[15px] font-bold">{place.name}</span>
            {(place.rating !== undefined || category) && (
              <span className="mt-1 flex items-center gap-1.5 text-[11.5px] text-ink-500">
                {place.rating !== undefined && (
                  <>
                    <Star className="size-3 fill-butter-400 text-butter-400" aria-hidden />
                    <span className="font-bold text-ink-700">{place.rating.toFixed(1)}</span>
                    {place.ratingCount !== undefined && (
                      <span>리뷰 {place.ratingCount.toLocaleString("ko-KR")}</span>
                    )}
                  </>
                )}
                {category && <span>{category}</span>}
              </span>
            )}
            {address && <span className="mt-1 block truncate text-[11.5px] text-ink-500">{address}</span>}
          </span>
          <a
            href={mapHref}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-9 flex-none items-center gap-1 rounded-full bg-purple-50 px-3.5 text-[12px] font-bold text-purple-600 transition-colors hover:bg-purple-100"
          >
            길찾기 <ArrowUpRight className="size-3.5" aria-hidden />
          </a>
        </div>
      </div>
    </section>
  );
}

function trustedPlaceImage(value?: string): string | undefined {
  const safe = safeHttpUrl(value);
  if (!safe) return undefined;
  const host = new URL(safe).hostname.toLowerCase();
  return host.endsWith(".googleusercontent.com") ? safe : undefined;
}

function MochiSummary({ item }: { item: ResolvedItem }) {
  const original = item.ocrText ?? item.text;
  return (
    <section
      aria-label="모찌가 정리했어요"
      className="mt-4 rounded-3xl border border-ink-100 bg-surface p-6 shadow-card"
    >
      <h2 className="flex items-center gap-2 text-[13px] font-bold text-ink-500">
        <Image src="/brand/mochi2.png" alt="" width={20} height={20} aria-hidden />
        모찌가 정리했어요
      </h2>
      <p className="mt-3 text-[15.5px] leading-relaxed text-ink-900 [text-wrap:pretty]">
        {item.summary}
      </p>
      {original && (
        <blockquote className="mt-4 whitespace-pre-wrap border-l-[3px] border-purple-200 pl-4 text-[13.5px] leading-relaxed text-ink-500">
          {original}
        </blockquote>
      )}
      {item.userMemo && (
        <p className="mt-4 rounded-xl bg-butter-50 px-4 py-3 text-[14px] font-medium text-[#6b5210]">
          내 메모: {item.userMemo}
        </p>
      )}
    </section>
  );
}
