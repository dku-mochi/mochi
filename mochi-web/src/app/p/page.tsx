import type { Metadata } from "next";
import { PERSONAS } from "@seed/index";
import type { IntentType } from "@seed/schema";
import { PersonaSelect, type PersonaCardData } from "@/components/persona/PersonaSelect";

export const metadata: Metadata = { title: "체험할 사람 선택" };

/*
 * S1 — 특정 계정이 아니라 "삶의 패턴이 다른 사람들"에게 작동함을 보여주는 선택 씬.
 * 시드 → 카드 요약(대표 캡처·intent 분포)은 서버에서 파생해 plain props 로 내린다.
 */

const INTENT_PRIORITY: IntentType[] = ["schedule", "todo", "knowledge", "memo"];

function toCard(p: (typeof PERSONAS)[number], recommended: boolean): PersonaCardData {
  const byIntent: Record<IntentType, number> = { schedule: 0, todo: 0, knowledge: 0, memo: 0 };
  for (const item of p.items) {
    const primary =
      INTENT_PRIORITY.find((t) => item.instances.some((i) => i.intentType === t)) ?? "memo";
    byIntent[primary] += 1;
  }
  const heroImages = p.heroSlugs
    .map((slug) => p.items.find((i) => i.slug === slug)?.image?.file)
    .filter((f): f is string => Boolean(f));
  // heroSlug 가 이미지 없는 카드(url·memo)면 다른 캡처로 3장을 채운다
  for (const item of p.items) {
    if (heroImages.length >= 3) break;
    if (item.image && !heroImages.includes(item.image.file)) heroImages.push(item.image.file);
  }

  return {
    slug: p.slug,
    name: p.name,
    age: p.age,
    job: p.job,
    tagline: p.tagline,
    intro: p.intro,
    accent: p.accent,
    heroImages,
    byIntent,
    itemCount: p.items.length,
    recommended,
  };
}

export default function PersonaSelectPage() {
  const cards = PERSONAS.map((p, i) => toCard(p, i === 0));
  return <PersonaSelect cards={cards} />;
}
