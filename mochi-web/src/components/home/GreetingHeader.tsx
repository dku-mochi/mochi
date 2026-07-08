"use client";

import { usePersona } from "@/components/journey/PersonaProvider";
import { RollingNumber } from "@/components/primitives/RollingNumber";
import { kstParts } from "@/lib/seedRuntime";

const DAY = 86_400_000;

export function GreetingHeader() {
  const { persona, items, now } = usePersona();
  const weekCount = items.filter((i) => now - i.capturedAt < 7 * DAY).length;
  const p = kstParts(now);

  return (
    <div>
      <p className="text-[13px] font-semibold text-ink-500 tracking-snug">
        {p.month}월 {p.day}일 ·{" "}
        {["일", "월", "화", "수", "목", "금", "토"][p.weekday]}요일
      </p>
      <h1 className="mt-1.5 font-display text-[27px] leading-snug tracking-head text-ink-900 [text-wrap:balance]">
        {persona.name.slice(1)}님이 이번 주 남긴{" "}
        <span className="inline-flex items-baseline text-purple-600">
          <RollingNumber value={weekCount} />개
        </span>
        , 모찌가 정리해뒀어요
      </h1>
    </div>
  );
}
