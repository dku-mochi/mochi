import { seedPersonaSchema, type SeedPersona } from "./schema";
import sena from "./personas/sena";
import dohyun from "./personas/dohyun";
import yuna from "./personas/yuna";

const raw = [sena, dohyun, yuna];

/** zod 통과본 — import 시점에 계약 위반이 곧바로 터지게 한다 */
export const PERSONAS: SeedPersona[] = raw.map((p) => seedPersonaSchema.parse(p));

export const PERSONA_SLUGS = PERSONAS.map((p) => p.slug);

export function getPersona(slug: string): SeedPersona | undefined {
  return PERSONAS.find((p) => p.slug === slug);
}
