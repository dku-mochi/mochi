import type { SampleCard, RecallCard } from "@/lib/types";

// ─────────────────────────────────────────────────────────────
// 실DB에서 추출한 샘플 5건 (owner 71503fa8…, 모두 analyzed).
// 라이브 /recall·/mochi_items가 우선이고, 이 seed는 정적 폴백 + autoplay 데이터 소스.
// 이미지는 BFF가 토큰으로 받아온 실제 캡처(public/seed/caps/<sha256>.jpg).
// ─────────────────────────────────────────────────────────────

const cap = (sha: string) => `/seed/caps/${sha}.jpg`;

export const SAMPLE_CARDS: SampleCard[] = [
  {
    id: "9393b19f",
    kind: "screenshot",
    title: "데이콘 경진대회 일정",
    oneline: "기획서 7/7 · 산출물 7/15 마감",
    source: "스크린샷",
    imageUrl: cap("112ac1c74352f2b73e89a8e93845ad99887e1ae5d91467a378277ca6e557ed57"),
    intents: ["schedule", "todo"],
    category: "커리어 개발",
    tint: "purple",
    savedAtIso: "2026-06-19T12:16:37+09:00",
  },
  {
    id: "bdb69bf5",
    kind: "screenshot",
    title: "DNS는 어떻게 동작하나",
    oneline: "계층 구조와 질의 과정 정리",
    source: "스크린샷",
    imageUrl: cap("4c48a50fd944b924b2324ba7fc9080af0416f774e469b06e7fac87d06314c131"),
    intents: ["knowledge"],
    category: "학업",
    tint: "mint",
    savedAtIso: "2026-06-12T17:54:53+09:00",
  },
  {
    id: "08d92295",
    kind: "screenshot",
    title: "남양주 여행",
    oneline: "친구들과 6/26–27",
    source: "스크린샷",
    imageUrl: cap("bb0a20f05d016cae2140ec5268019a4bb8d428c46799615ef97a5bc8d9fd4bf0"),
    intents: ["schedule"],
    category: "일상",
    tint: "sky",
    savedAtIso: "2026-06-16T13:42:14+09:00",
  },
  {
    id: "493a82fc",
    kind: "link",
    title: "허니콤보 공짜 받는 법",
    oneline: "스탬플리 앱 소개 영상",
    source: "YouTube",
    intents: ["memo"],
    category: "일상",
    tint: "peach",
    savedAtIso: "2026-06-14T17:29:21+09:00",
  },
  {
    id: "33c2d191",
    kind: "screenshot",
    title: "학자금 이자 납부",
    oneline: "납부 기한 6/19",
    source: "스크린샷",
    imageUrl: cap("618978bcb719dc7e70d3c391cbb29f7bda8c39b8f1f0e098a285d7e2b9688a2b"),
    intents: ["todo"],
    category: "투자",
    tint: "butter",
    savedAtIso: "2026-06-15T18:06:09+09:00",
  },
];

// 회수(타임머신) 폴백 — 세 규칙(마감/지식decay/유사도)을 모두 보여주는 게 목적.
export const RECALL_CARDS: RecallCard[] = [
  {
    ...SAMPLE_CARDS[0],
    daysAgo: 9,
    reason: { kind: "deadline", label: "마감 임박", detail: "기획서 제출이 며칠 안 남았어요" },
  },
  {
    ...SAMPLE_CARDS[1],
    daysAgo: 16,
    reason: { kind: "decay", label: "다시 볼 때", detail: "저장하고 16일째 안 펼쳐보셨어요" },
  },
  {
    ...SAMPLE_CARDS[3],
    daysAgo: 14,
    reason: { kind: "similarity", label: "비슷한 기록", detail: "요즘 담은 것들과 결이 닿아요" },
  },
];
