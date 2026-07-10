import type { SeedCannedChat, SeedCannedSearch } from "../schema";

export const dohyunChat: SeedCannedChat[] = [
  {
    id: "dohyun-search-outline",
    triggers: ["검색", "발표", "목차", "개선", "스터디"],
    script: [
      { type: "tool_started", name: "search_items", label: "기록을 뒤지고 있어요…" },
      {
        type: "tool_finished",
        name: "search_items",
        summary: "검색 개선 기록 3건 + 발표 메모 1건",
      },
      {
        type: "message_delta",
        text: "모아둔 검색 자료로 발표 목차를 잡아봤어요.\n\n1. **문제 정의** - p99 지연과 정확 일치 질의 붕괴\n2. **인덱스 튜닝**[1] - pgvector HNSW, m·ef_construction 실측\n3. **하이브리드 검색**[2] - BM25 + 벡터를 RRF 융합\n4. **리랭킹**[3] - cross-encoder 로 top-k 품질, 비용 트레이드오프\n5. **적용 로드맵** - 1→2→3 순서 제안\n\n발표 목차 초안 마감이 D-5 라, 이대로 메모로 만들어둘까요?",
      },
      { type: "citation", index: 1, itemSlug: "blog-pgvector" },
      { type: "citation", index: 2, itemSlug: "blog-hybrid-search" },
      { type: "citation", index: 3, itemSlug: "blog-reranker" },
      {
        type: "proposal",
        proposalType: "create_memo",
        payload: {
          title: "검색 개선기 발표 목차 v1",
          note: "문제정의 → HNSW 튜닝 → 하이브리드 → 리랭킹 → 로드맵",
        },
      },
    ],
  },
  {
    id: "dohyun-kakao-link",
    triggers: ["카톡", "모니터링", "grafana", "그라파나", "링크", "받았"],
    script: [
      { type: "tool_started", name: "search_items", label: "카카오톡으로 받은 기록을 찾고 있어요…" },
      {
        type: "tool_finished",
        name: "search_items",
        summary: "카카오톡 출처 링크 1건",
      },
      {
        type: "message_delta",
        text: "9일 전에 카카오톡으로 받아둔 글이 있어요.\n\n**Grafana로 API 지연 잡아낸 이야기**[1] - p99 지연 원인을 대시보드로 좁혀가는 실전기예요. 저장할 때 '선배가 준 링크. 나중에 정독'이라고 메모해두셨어요.\n\n지금이 그 '나중'인 것 같네요.",
      },
      { type: "citation", index: 1, itemSlug: "kakao-monitoring-link" },
    ],
  },
];

export const dohyunSearch: SeedCannedSearch[] = [
  {
    id: "dohyun-search-improve",
    triggers: ["검색", "pgvector", "리랭", "하이브리드"],
    answer:
      "검색 개선 자료 3건 - HNSW 튜닝, 하이브리드 설계, 리랭커 비교가 스터디 발표 재료로 모여 있어요.",
    citationSlugs: ["blog-pgvector", "blog-hybrid-search", "blog-reranker"],
  },
  {
    id: "dohyun-search-monitoring",
    triggers: ["모니터링", "카톡", "grafana", "지연"],
    answer: "카카오톡으로 받은 Grafana 실전기 1건 - 아직 안 읽으셨어요.",
    citationSlugs: ["kakao-monitoring-link"],
  },
  {
    id: "dohyun-search-schedule",
    triggers: ["일정", "다음 주", "이번 주"],
    answer:
      "가까운 일정 - 파이콘 티켓팅(금 10:00), 정기 배포(금 11:00), 치과(월 18:30) 순이에요.",
    citationSlugs: ["pycon-ticket", "deploy-schedule", "dentist"],
  },
];
