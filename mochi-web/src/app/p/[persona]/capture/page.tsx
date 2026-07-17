import { notFound } from "next/navigation";
import { CaptureScene } from "@/components/capture/CaptureScene";
import { captureExamplesFor } from "@/lib/captureExamples";
import { getPersona } from "@seed/index";

/* S2 기록 — 캡처는 0노력, 정리는 자동 (분류는 행동으로만 드러난다) */
export default async function CapturePage({
  params,
}: {
  params: Promise<{ persona: string }>;
}) {
  const { persona: slug } = await params;
  const persona = getPersona(slug);
  if (!persona) notFound();

  return <CaptureScene examples={captureExamplesFor(persona)} />;
}
