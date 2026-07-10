import { notFound } from "next/navigation";
import { getPersona } from "@seed/index";
import { DetailScene } from "@/components/detail/DetailScene";

export default async function ItemDetailPage({
  params,
}: {
  params: Promise<{ persona: string; slug: string }>;
}) {
  const { persona: personaSlug, slug } = await params;
  const persona = getPersona(personaSlug);
  // `live-` slug 는 세션 오버레이(브라우저에만 있는 내 기록) — 클라이언트가 해석한다
  if (!persona || !(persona.items.some((i) => i.slug === slug) || slug.startsWith("live-"))) {
    notFound();
  }

  return <DetailScene slug={slug} />;
}
