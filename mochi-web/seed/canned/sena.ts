import type { SeedCannedChat, SeedCannedSearch } from "../schema";

/* 폴백 채팅 — 라이브와 같은 wire 포맷으로 재생된다 (BFF fallback) */
export const senaChat: SeedCannedChat[] = [
  {
    id: "sena-ai-materials",
    triggers: ["ai", "에이전트", "agent", "자료", "정리", "langchain", "rag"],
    script: [
      { type: "tool_started", name: "search_items", label: "기록을 뒤지고 있어요…" },
      {
        type: "tool_finished",
        name: "search_items",
        summary: "AI 에이전트 관련 기록 3건",
      },
      {
        type: "message_delta",
        text: "지난주에 담아둔 AI 에이전트 자료는 세 건이에요.\n\n1. **LangChain 에이전트 입문 강의**[1] — 계획→도구 호출→관찰 루프를 40분에 훑어요. 실습 코드 링크가 있어 제일 먼저 보기 좋아요.\n2. **RAG 구조 한 번에 이해하기**[2] — 인덱싱과 검색·생성 두 단계 정리. 졸업 프로젝트 검색 기능 설계에 바로 닿는 내용이에요.\n3. **에이전트 동향 뉴스레터**[3] — 멀티 에이전트 협업 사례가 레퍼런스 후보예요.\n\n금요일 졸프 면담 전이라면 1·2번만 먼저 보셔도 충분해요.",
      },
      { type: "citation", index: 1, itemSlug: "youtube-langchain" },
      { type: "citation", index: 2, itemSlug: "blog-rag-intro" },
      { type: "citation", index: 3, itemSlug: "newsletter-agents" },
      {
        type: "proposal",
        proposalType: "reminder",
        payload: {
          title: "면담 전 AI 자료 훑기",
          note: "목요일 저녁 알림",
          time: "목 20:00",
        },
      },
    ],
  },
  {
    id: "sena-week-todos",
    triggers: ["할 일", "할일", "해야", "남았", "이번 주", "마감"],
    script: [
      { type: "tool_started", name: "search_items", label: "이번 주 마감을 모으고 있어요…" },
      {
        type: "tool_finished",
        name: "search_items",
        summary: "미완료 할 일 중 이번 주 마감 3건",
      },
      {
        type: "message_delta",
        text: "이번 주 안에 끝내야 하는 건 세 가지예요.\n\n- **스터디 문제 풀기**[3] — 토요일 스터디 전까지 (D-3)\n- **졸프 면담 슬라이드 3장** — 금요일 면담 전까지 (D-3)\n- **운영체제 과제 4**[1] — 일요일 23:59, 지연 시 일당 10% 감점\n\n발표 대본 수정[2]은 다음 주 화요일 발표 전까지라 이번 주말에 시작해도 늦지 않아요. 과제부터 잡는 걸 추천해요.",
      },
      { type: "citation", index: 1, itemSlug: "lms-os-assignment" },
      { type: "citation", index: 2, itemSlug: "memo-presentation-script" },
      { type: "citation", index: 3, itemSlug: "boj-problem" },
    ],
  },
];

export const senaSearch: SeedCannedSearch[] = [
  {
    id: "sena-search-ai",
    triggers: ["ai", "에이전트", "agent", "langchain", "rag"],
    answer:
      "지난주에 저장한 AI 에이전트 자료 3건 — LangChain 입문 강의, RAG 구조 정리, 동향 뉴스레터가 이어져 있어요.",
    citationSlugs: ["youtube-langchain", "blog-rag-intro", "newsletter-agents"],
  },
  {
    id: "sena-search-deadline",
    triggers: ["마감", "이번 주", "제출", "과제"],
    answer:
      "이번 주 마감은 운영체제 과제 4(일요일 23:59)가 가장 급하고, 발표 대본과 인턴 서류가 그 뒤를 따라요.",
    citationSlugs: ["lms-os-assignment", "memo-presentation-script", "intern-notice"],
  },
  {
    id: "sena-search-dacon",
    triggers: ["데이콘", "경진", "공모"],
    answer: "데이콘 경진대회 — 최종 산출물이 7/15 마감이에요. 창업 공모전 접수는 7/27까지.",
    citationSlugs: ["dacon-contest", "contest-poster"],
  },
];
