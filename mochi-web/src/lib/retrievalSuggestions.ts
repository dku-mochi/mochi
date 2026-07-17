import type { ResolvedItem } from "@/lib/seedRuntime";

export interface RetrievalSuggestions {
  search: { query: string; label: string };
  chat: { text: string; label: string };
}

interface SuggestionRule {
  match: RegExp;
  query: string;
  question: string;
}

/*
 * 분석 결과를 다시 제목으로 복사하지 않고, 사람이 기억할 법한 상위 개념으로 넓힌다.
 * 규칙은 예시 id가 아니라 도메인 신호를 본다. 라이브 분석과 폴백 분석 모두 같은 경로다.
 */
const RULES: SuggestionRule[] = [
  {
    match: /회식|팀\s*(점심|저녁)|단체\s*(식사|예약)/i,
    query: "회식 장소",
    question: "저번에 저장했던 괜찮은 회식 장소들 뭐였지?",
  },
  {
    match: /레시피|요리법|원팬|장보기/i,
    query: "해보고 싶던 레시피",
    question: "전에 저장해둔 레시피에서 재료와 순서가 어떻게 됐지?",
  },
  {
    match: /카페|베이커리|브런치|소금빵|커피|라떼/i,
    query: "가보고 싶던 카페",
    question: "전에 저장해둔 카페 중에 다음에 가볼 만한 곳이 어디였지?",
  },
  {
    match: /맛집|식당|먹거리|간식|피자|덮밥|파스타|요리/i,
    query: "먹어보고 싶던 곳",
    question: "전에 먹어보려고 저장한 곳이나 메뉴가 뭐였지?",
  },
  {
    match: /여행|당일치기|숙소|스테이|제주|남양주|가평|나들이/i,
    query: "다음에 갈 곳",
    question: "전에 저장해둔 여행 후보에서 어디부터 가보려고 했지?",
  },
  {
    match: /공연|콘서트|전시|미술관|티켓|페스티벌|축제|pycon|컨퍼런스/i,
    query: "가보고 싶던 행사",
    question: "전에 저장해둔 행사의 일정과 장소가 어떻게 됐지?",
  },
  {
    match: /결혼식|웨딩|청첩장/i,
    query: "다가오는 결혼식",
    question: "저장해둔 결혼식은 언제고 뭘 챙겨야 했지?",
  },
  {
    match: /사이드\s*프로젝트|프로젝트\s*아이디어|팝업스토어|공간\s*(레퍼런스|디자인)/i,
    query: "아이디어 레퍼런스",
    question: "전에 저장해둔 아이디어에서 다시 써볼 만한 포인트가 뭐였지?",
  },
  {
    match: /책|도서|서점|독서|ddia|밑줄|문장|영화|볼\s*것/i,
    query: "다시 보고 싶던 콘텐츠",
    question: "전에 저장해둔 것 중 다시 읽거나 보고 싶었던 게 뭐였지?",
  },
  {
    match: /꽃|플라워|원데이클래스/i,
    query: "취미로 해볼 것",
    question: "전에 저장해둔 취미 아이디어에서 기억해둘 내용이 뭐였지?",
  },
  {
    match: /러닝|필라테스|\bpt\b|운동|헬스|5km/i,
    query: "운동 계획",
    question: "전에 적어둔 운동 계획에서 시간이나 장소가 어떻게 됐지?",
  },
  {
    match: /치과|병원|진료|스케일링|건강검진/i,
    query: "병원 예약",
    question: "전에 저장해둔 병원 일정이 언제였지?",
  },
  {
    match: /인턴|채용|이력서|포트폴리오|공모전|경진대회|데이콘/i,
    query: "커리어 준비",
    question: "전에 저장한 지원이나 대회 정보에서 마감과 준비할 게 뭐였지?",
  },
  {
    match: /과제|lms|시험|수업|팀플|발표|스터디|오피스아워|교수님/i,
    query: "학교에서 챙길 것",
    question: "학교 관련해서 저장해둔 것 중 다음으로 챙길 일이 뭐였지?",
  },
  {
    match: /장애|oom|에러|오류|지연|grafana|모니터링|회고/i,
    query: "운영 이슈",
    question: "전에 저장한 운영 이슈에서 원인과 다시 볼 포인트가 뭐였지?",
  },
  {
    match: /배포|마이그레이션|코드\s*리뷰|롤백|체크리스트/i,
    query: "배포 전 점검",
    question: "저장해둔 배포 관련 기록에서 빠뜨리면 안 되는 게 뭐였지?",
  },
  {
    match: /pgvector|hnsw|하이브리드\s*검색|리랭커|rerank|검색\s*(성능|개선)/i,
    query: "검색 성능 자료",
    question: "전에 모아둔 검색 개선 자료들을 비교하면 어떤 선택지가 있었지?",
  },
  {
    match: /kubernetes|\bk8s\b|kubectl|api|dns|python|asyncio|langchain|\brag\b|시스템\s*디자인|개발/i,
    query: "개발 참고자료",
    question: "전에 저장해둔 개발 자료에서 실무에 써볼 만한 내용이 뭐였지?",
  },
  {
    match: /선물|생신|생일/i,
    query: "선물 후보",
    question: "전에 골라둔 선물 후보가 뭐였고 언제까지 준비해야 했지?",
  },
  {
    match: /원피스|옷|사이즈|쇼핑|구매|쿠폰|가격|위시리스트|구독/i,
    query: "고민하던 쇼핑",
    question: "전에 저장해둔 쇼핑 후보에서 가격이나 조건이 어떻게 됐지?",
  },
  {
    match: /미용실|헤어|애쉬브라운|염색|뷰티/i,
    query: "뷰티 예약",
    question: "전에 적어둔 예약에서 원하는 스타일과 시간이 어떻게 됐지?",
  },
  {
    match: /학자금|이자|연말정산|영수증|월급|예산|계좌|회비/i,
    query: "돈 관련 할 일",
    question: "전에 저장해둔 돈 관련 기록에서 기한이나 챙길 서류가 뭐였지?",
  },
  {
    match: /약속|만나|집결|모임|예약/i,
    query: "약속 장소",
    question: "전에 저장한 약속은 언제 어디에서 만나기로 했지?",
  },
];

const GENERIC_CATEGORIES = new Set(["", "웹 저장", "일정", "할 일", "할일", "메모", "기록"]);
const DROP_TOKENS = new Set([
  "저장",
  "저장한",
  "캡처",
  "캡처한",
  "스크린샷",
  "링크",
  "메모",
  "공지",
  "후보",
  "정리",
  "확인",
  "관련",
  "이번",
  "다음",
  "지난",
]);

function corpus(item: ResolvedItem): string {
  return [
    item.retrievalHint,
    item.title,
    item.summary,
    item.category,
    item.text,
    item.ocrText,
    item.userMemo,
    item.place?.name,
    item.place?.category,
    ...item.instances.flatMap((instance) => [
      instance.label,
      instance.payload?.title,
      instance.payload?.topic,
      instance.payload?.note,
    ]),
  ]
    .filter(Boolean)
    .join(" ");
}

function headline(item: ResolvedItem): string {
  return [
    item.retrievalHint,
    item.title,
    item.category,
    item.place?.category,
  ]
    .filter(Boolean)
    .join(" ");
}

function broadCue(item: ResolvedItem): string {
  const category = item.category.trim();
  if (!GENERIC_CATEGORIES.has(category)) {
    const parts = category.split(/[·/|>]/).map((part) => part.trim()).filter(Boolean);
    const useful = parts.at(-1);
    if (useful && useful !== item.title.trim()) return `${useful} 관련`;
  }

  const source = item.retrievalHint ?? item.title;
  const tokens = source
    .replace(/https?:\/\/\S+/gi, " ")
    .replace(/[0-9]+(?:[.:/-][0-9]+)*/g, " ")
    .replace(/[^0-9a-zA-Z가-힣]+/g, " ")
    .split(/\s+/)
    .filter((token) => token.length > 1 && !DROP_TOKENS.has(token))
    .slice(0, 2);
  const cue = tokens.join(" ").trim();
  if (cue && cue !== item.title.trim()) return cue;
  return item.primaryIntent === "schedule"
    ? "다가오는 일정"
    : item.primaryIntent === "todo"
      ? "챙길 일"
      : item.primaryIntent === "knowledge"
        ? "다시 볼 자료"
        : "나중에 볼 것";
}

function genericQuestion(item: ResolvedItem, cue: string): string {
  if (item.place) return `전에 저장해둔 ${cue} 장소가 어디였지?`;
  if (item.primaryIntent === "schedule") return `전에 저장해둔 ${cue} 일정이 언제였지?`;
  if (item.primaryIntent === "todo") return `저번에 적어둔 ${cue}, 내가 뭘 챙기려고 했지?`;
  if (item.primaryIntent === "knowledge") return `전에 저장해둔 ${cue} 자료에서 핵심이 뭐였지?`;
  return `전에 저장해둔 ${cue} 내용이 뭐였지?`;
}

/** 최근 기록 하나로 검색과 질문의 서로 다른 회수 단서를 만든다. */
export function retrievalSuggestionsFor(item: ResolvedItem): RetrievalSuggestions {
  const text = corpus(item);
  const matched =
    RULES.find((rule) => rule.match.test(headline(item))) ??
    RULES.find((rule) => rule.match.test(text));
  const query = matched?.query ?? broadCue(item);
  const question = matched?.question ?? genericQuestion(item, query);
  return {
    search: { query, label: query },
    chat: { text: question, label: question },
  };
}
