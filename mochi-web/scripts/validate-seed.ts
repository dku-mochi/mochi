import { existsSync } from "node:fs";
import { join } from "node:path";
import { seedPersonaSchema } from "../seed/schema";
import sena from "../seed/personas/sena";
import dohyun from "../seed/personas/dohyun";
import yuna from "../seed/personas/yuna";

/*
 * 시드 무결성 검증 — 빌드 전 실행.
 * zod 계약 + 이미지 실존 + slug 참조 무결성 + 마감 payload 정합.
 */
const personas = [sena, dohyun, yuna];
const errors: string[] = [];

for (const raw of personas) {
  const parsed = seedPersonaSchema.safeParse(raw);
  if (!parsed.success) {
    errors.push(
      `[${raw.slug}] zod 실패:\n${parsed.error.issues
        .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
        .join("\n")}`,
    );
    continue;
  }
  const p = parsed.data;
  const slugs = new Set<string>();

  for (const item of p.items) {
    if (slugs.has(item.slug)) errors.push(`[${p.slug}] slug 중복: ${item.slug}`);
    slugs.add(item.slug);

    if (item.image) {
      const abs = join(process.cwd(), "public", item.image.file);
      if (!existsSync(abs)) errors.push(`[${p.slug}/${item.slug}] 이미지 없음: ${item.image.file}`);
    }

    for (const inst of item.instances) {
      if (inst.intentType === "schedule" && inst.payload?.dateInDays === undefined)
        errors.push(`[${p.slug}/${item.slug}] schedule instance에 dateInDays 없음`);
      if (inst.intentType === "todo" && !inst.done && inst.payload?.deadlineInDays === undefined)
        errors.push(`[${p.slug}/${item.slug}] 미완료 todo에 deadlineInDays 없음`);
    }
  }

  const ref = (slug: string, where: string) => {
    if (!slugs.has(slug)) errors.push(`[${p.slug}] ${where} 참조 깨짐: ${slug}`);
  };
  p.items.forEach((it) => it.relatedSlugs?.forEach((s) => ref(s, `${it.slug}.relatedSlugs`)));
  p.recall.forEach((r) => ref(r.itemSlug, "recall"));
  p.heroSlugs.forEach((s) => ref(s, "heroSlugs"));
  p.cannedSearch.forEach((c) => c.citationSlugs.forEach((s) => ref(s, `cannedSearch.${c.id}`)));
  p.cannedChat.forEach((c) =>
    c.script.forEach((e) => {
      if (e.type === "citation") ref(e.itemSlug, `cannedChat.${c.id}`);
    }),
  );

  // 회수 이유 4종이 3인 합산으로 전부 등장하는지는 아래 전역 체크에서
}

const allKinds = new Set(personas.flatMap((p) => p.recall.map((r) => r.kind)));
for (const k of ["fadingValue", "relatedCluster", "revisitedOften", "linkedToRecent"]) {
  if (!allKinds.has(k as never)) errors.push(`회수 이유 미등장: ${k}`);
}

if (errors.length) {
  console.error(`✗ 시드 검증 실패 (${errors.length}건)\n`);
  errors.forEach((e) => console.error(e));
  process.exit(1);
}

const total = personas.reduce((n, p) => n + p.items.length, 0);
console.log(
  `✓ 시드 검증 통과 — 페르소나 ${personas.length}명, 아이템 ${total}건, 회수 ${personas.reduce((n, p) => n + p.recall.length, 0)}건`,
);
