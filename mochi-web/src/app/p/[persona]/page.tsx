import { RiseIn } from "@/components/primitives/RiseIn";
import { GreetingHeader } from "@/components/home/GreetingHeader";
import { RecentMosaic } from "@/components/home/RecentMosaic";
import { MonthlyMiniReport } from "@/components/home/MonthlyMiniReport";
import { TodayColumn } from "@/components/home/TodayColumn";

/* S3 홈 — 쌓인 기록이 생활 동선(할일·마감·최근)으로 정돈된 상태를 증명 */
export default function HomeScenePage() {
  return (
    <main className="mx-auto grid max-w-6xl grid-cols-1 gap-8 px-5 py-8 lg:grid-cols-12">
      <div className="space-y-8 lg:col-span-8">
        <RiseIn index={0}>
          <GreetingHeader />
        </RiseIn>
        <RiseIn index={1}>
          <RecentMosaic />
        </RiseIn>
      </div>
      <div className="lg:col-span-4">
        <div className="space-y-4 lg:sticky lg:top-20">
          <RiseIn index={2}>
            <TodayColumn />
          </RiseIn>
          <RiseIn index={4}>
            <MonthlyMiniReport />
          </RiseIn>
        </div>
      </div>
    </main>
  );
}
