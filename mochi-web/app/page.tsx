import { JudgeModeProvider, JudgeToggle } from "@/components/JudgeMode";
import { Autoplay } from "@/components/Autoplay";
import { Hero } from "@/components/sections/Hero";
import { StorySave } from "@/components/sections/StorySave";
import { LiveProof } from "@/components/sections/LiveProof";
import { Timemachine } from "@/components/sections/Timemachine";
import { SensitiveGuard } from "@/components/sections/SensitiveGuard";
import { SiteFooter } from "@/components/sections/SiteFooter";

/* ─────────────────────────────────────────────────────────────
   랜딩 — 단일 영웅 경로. 섹션을 시간 순서로 조합한다:
   Hero → 보이지 않는 정리 → Live 증명 → 타임머신(회수) → 민감 보호 → 푸터.
   JudgeModeProvider 가 전체를 감싸 BehaviorMark 가 심사위원 라벨을 읽는다.
   ───────────────────────────────────────────────────────────── */

export default function Home() {
  return (
    <JudgeModeProvider>
      <JudgeToggle />
      <Autoplay />
      <main className="bg-canvas font-sans">
        <Hero />
        <StorySave />
        <LiveProof />
        <Timemachine />
        <SensitiveGuard />
        <SiteFooter />
      </main>
    </JudgeModeProvider>
  );
}
