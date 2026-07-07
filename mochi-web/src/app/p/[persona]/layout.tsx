import { notFound } from "next/navigation";
import { getPersona } from "@seed/index";
import { PersonaProvider } from "@/components/journey/PersonaProvider";
import { SceneNav } from "@/components/journey/SceneNav";

// 시간축(며칠 전·D-day)이 요청 시각 기준이라 정적 프리렌더 대신 요청마다 계산
export const dynamic = "force-dynamic";

export default async function PersonaLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ persona: string }>;
}) {
  const { persona: slug } = await params;
  const persona = getPersona(slug);
  if (!persona) notFound();

  // 서버 컴포넌트에서 요청 시각을 1회 주입 — 클라 하이드레이션 불일치 방지 (의도된 비순수)
  // eslint-disable-next-line react-hooks/purity
  const now = Date.now();

  return (
    <PersonaProvider persona={persona} now={now}>
      <SceneNav />
      {children}
    </PersonaProvider>
  );
}
