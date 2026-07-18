"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { RiseIn } from "@/components/primitives/RiseIn";
import { useJourneySession, type JourneyStep } from "@/lib/journeySession";
import { readStats, type LiveStats } from "@/lib/liveStats";

const GROUPS: Array<{
  icon: string;
  title: string;
  steps: JourneyStep[];
  complete: (captureTitle?: string, proposal?: "confirmed" | "preview") => string;
}> = [
  {
    icon: "/intents/cat-document.png",
    title: "남겼다",
    steps: ["capture", "home"],
    complete: (title) =>
      title
        ? `‘${title}’ 기록을 보내고, 모찌가 정리해 홈에 쌓은 모습까지 확인했어요.`
        : "기록을 보내고 모찌가 정리해 홈에 쌓은 모습까지 확인했어요.",
  },
  {
    icon: "/intents/cat-checklist.png",
    title: "찾았다",
    steps: ["search", "chat"],
    complete: (_, proposal) =>
      `검색과 질문으로 기록을 다시 꺼냈어요.${proposal === "confirmed" ? " 제안한 작업도 실제로 반영했어요." : proposal === "preview" ? " 기기 작업은 iOS 확정 화면까지 미리 봤어요." : " 자유 입력과 추천을 모두 사용할 수 있어요."}`,
  },
  {
    icon: "/intents/cat-book.png",
    title: "떠올랐다",
    steps: ["recall"],
    complete: () => "남겨둔 기록이 왜 지금 필요한지 이유와 함께 먼저 떠오르는 순간을 확인했어요.",
  },
];

export function JourneyOutcome() {
  const journey = useJourneySession();
  const [stats, setStats] = useState<LiveStats | null>(null);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- sessionStorage 는 마운트 후에만 읽을 수 있다
    setStats(readStats());
  }, []);

  const captured = journey?.steps.capture.status === "completed";
  const recalled = journey?.steps.recall.status === "completed";
  const headline = captured
    ? recalled
      ? <>기록은 남았고,<br />필요할 때 <span className="text-purple-600">떠올랐어요</span></>
      : <>기록을 남기고,<br /><span className="text-purple-600">다시 꺼내봤어요</span></>
    : <>모찌의 기억 흐름을<br /><span className="text-purple-600">둘러봤어요</span></>;

  const evidence = stats && stats.live > 0
    ? `이번 체험에서 실제 백엔드 응답 ${stats.live}건을 확인했어요.`
    : stats && stats.fallback > 0
      ? "현재 연결에서는 제품과 같은 포맷의 폴백 응답으로 체험했어요."
      : "완료한 단계만 아래에 정리했어요.";

  return (
    <>
      <RiseIn index={0}>
        <div className="flex flex-col items-center text-center">
          <div className="mochi-walk" role="img" aria-label="걸어가는 모찌" />
          <h1 className="mt-6 font-display text-[clamp(26px,4.5vw,42px)] tracking-head [text-wrap:balance]">
            {headline}
          </h1>
          <p className="mt-4 max-w-lg text-[14.5px] leading-relaxed text-ink-700">
            {evidence} 각 단계의 결과는 방금 이 브라우저에서 한 행동을 기준으로 표시해요.
          </p>
        </div>
      </RiseIn>

      <div className="mt-14 grid gap-5 md:grid-cols-3">
        {GROUPS.map((group, index) => {
          const statuses = group.steps.map((step) => journey?.steps[step].status ?? "pending");
          const complete = statuses.every((status) => status === "completed");
          const skipped = statuses.some((status) => status === "skipped");
          const body = complete
            ? group.complete(journey?.capture?.title, journey?.proposal)
            : skipped
              ? "이 단계는 건너뛰었어요. 체험 안내와 상관없이 상단 메뉴에서 언제든 자유롭게 볼 수 있어요."
              : "아직 이 단계에서 행동하지 않았어요. 실제로 확인한 것만 완료로 기록해요.";
          return (
            <RiseIn key={group.title} index={index + 1} inView>
              <article className="h-full rounded-lg border border-ink-100 bg-surface p-6 shadow-card">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex size-12 items-center justify-center rounded-xl bg-lavender-200/50">
                    <Image src={group.icon} alt="" width={32} height={32} />
                  </div>
                  <span className="rounded-full bg-bg px-2.5 py-1 text-[10.5px] font-bold text-ink-500">
                    {complete ? "완료" : skipped ? "건너뜀" : "미체험"}
                  </span>
                </div>
                <h2 className="mt-3.5 font-display text-[19px] tracking-head">{group.title}</h2>
                <p className="mt-2 text-[13.5px] leading-relaxed text-ink-700">{body}</p>
              </article>
            </RiseIn>
          );
        })}
      </div>
    </>
  );
}
