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
  if (!persona || !persona.items.some((i) => i.slug === slug)) notFound();

  return <DetailScene slug={slug} />;
}
