"use client";

import { useEffect, useState } from "react";
import { readStats, type LiveStats } from "@/lib/liveStats";

/*
 * 피날레 증거 한 줄 — "작동하는 제품입니다"를 주장에서 숫자로.
 * 방금 여정에서 실제로 오간 네트워크 응답의 라이브/폴백 집계를 보여준다.
 * 집계가 없으면(네트워크 씬을 건너뜀) 조용히 사라진다.
 */
export function LiveEvidence() {
  const [stats, setStats] = useState<LiveStats | null>(null);

  useEffect(() => {
    // sessionStorage 는 클라이언트 전용 — 마운트 후 1회 판독
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStats(readStats());
  }, []);

  if (!stats) return null;
  const total = stats.live + stats.fallback;
  if (total === 0) return null;

  return (
    <p className="mt-3 rounded-xl bg-purple-50 px-4 py-3 text-[12.5px] leading-relaxed text-ink-700">
      <span className="font-bold text-purple-600">방금 이 체험에서</span>{" "}
      {stats.fallback > 0 ? (
        <>
          오간 채팅·검색·분석 응답 <span className="font-bold tnum">{total}건</span> 중{" "}
          <span className="font-bold tnum">{stats.live}건</span>을 실제 백엔드가 답했고,
          나머지 <span className="font-bold tnum">{stats.fallback}건</span>도 같은
          포맷으로 즉시 답했어요.
        </>
      ) : (
        <>
          오간 채팅·검색·분석 응답 <span className="font-bold tnum">{total}건</span> 전부를
          실제 백엔드가 답했어요.
        </>
      )}
    </p>
  );
}
