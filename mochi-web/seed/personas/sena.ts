import type { SeedPersona } from "../schema";
import { senaChat, senaSearch } from "../canned/sena";

/*
 * 김세나 — 23, 컴퓨터공학 4학년.
 * 페인포인트: 과제·공지를 캡처는 해두는데, 마감은 캘린더에 없다 (PRODUCT.md §2.1).
 * intent 무게중심: 일정 + 할일. 서사 축:
 *  1) 학업 — 운영체제 과제, 팀플 발표, 데이콘 경진대회
 *  2) AI 에이전트 학습 클러스터 — 지난주에 담은 3건 (채팅 "AI Agent 자료 정리" 시나리오)
 *  3) 커리어 — 인턴 공고, 공모전
 * 이미지: 실DB 캡처 3장(데이콘·DNS·학자금) + 목업 캡처 7장.
 */
const sena: SeedPersona = {
  slug: "sena",
  name: "김세나",
  age: 23,
  job: "컴퓨터공학과 4학년",
  tagline: "과제 공지는 캡처했는데, 마감은 놓칠 뻔한다",
  intro:
    "수업·팀플·공모전이 겹치는 학기말. 스크린샷은 쌓이는데 다시 열어보는 건 늘 마감 직전이다.",
  uuidEnvKey: "MOCHI_PERSONA_UUID_SENA",
  accent: "sky",
  heroSlugs: ["lms-os-assignment", "youtube-langchain", "dacon-contest"],
  suggestedSearch: [
    "지난주에 저장한 AI 에이전트 자료",
    "이번 주 마감인 것",
    "데이콘 일정",
  ],
  suggestedChat: [
    "지난주에 저장한 AI Agent 관련 자료 정리해줘",
    "이번 주에 해야 할 일 뭐가 남았지?",
  ],
  items: [
    // ── 학업: 과제·팀플 ──────────────────────────────
    {
      slug: "lms-os-assignment",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "운영체제 4차 과제 공지",
      ocrText:
        "[운영체제] 과제 4 공지 — 페이지 교체 알고리즘 시뮬레이터 구현. 제출: 7월 12일(일) 23:59, LMS 업로드. 지연 제출 시 일당 10% 감점.",
      category: "학교·과제",
      summary:
        "운영체제 4차 과제 — 페이지 교체 알고리즘 시뮬레이터. 7/12(일) 23:59 LMS 제출, 지연 시 일당 10% 감점.",
      instances: [
        {
          intentType: "schedule",
          label: "운영체제 과제 4 제출",
          payload: { title: "운영체제 과제 4 제출", dateInDays: 5, time: "23:59" },
        },
        {
          intentType: "todo",
          label: "페이지 교체 시뮬레이터 구현",
          payload: { title: "페이지 교체 시뮬레이터 구현", deadlineInDays: 5 },
        },
      ],
      image: { file: "/seed/caps/sena-lms-os.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 2,
      relatedSlugs: ["memo-presentation-script", "kakao-team-decision"],
    },
    {
      slug: "memo-presentation-script",
      kind: "memo",
      channel: "appIntent",
      source: "백탭 메모",
      title: "발표 대본 수정",
      text: "다음 주까지 발표 대본 수정하기. 도입부 데모 영상 먼저 → 아키텍처 설명 순서로 바꾸기.",
      category: "학교·팀플",
      summary:
        "팀플 발표 대본 수정 — 도입부를 데모 영상 먼저 보여주는 구성으로 변경. 다음 주까지.",
      instances: [
        {
          intentType: "todo",
          label: "발표 대본 수정",
          payload: { title: "발표 대본 수정", deadlineInDays: 7 },
        },
      ],
      capturedDaysAgo: 1,
      relatedSlugs: ["lms-os-assignment", "kakao-team-decision"],
    },
    {
      slug: "kakao-team-decision",
      kind: "screenshot",
      channel: "kakaoTalk",
      source: "카카오톡",
      title: "팀플 역할 분담 정리",
      ocrText:
        "지우: 그럼 세나가 발표, 내가 슬라이드, 현우가 데모 영상 / 현우: ㅇㅋ 목요일까지 초안 올릴게 / 지우: 발표는 다음 주 화요일 3시 확정!",
      category: "학교·팀플",
      summary:
        "팀플 역할 확정 — 세나 발표, 지우 슬라이드, 현우 데모 영상(목요일 초안). 발표는 다음 주 화요일 15:00.",
      instances: [
        {
          intentType: "schedule",
          label: "팀플 발표",
          payload: { title: "캡스톤 팀플 발표", dateInDays: 8, time: "15:00" },
        },
        { intentType: "memo", label: "역할 분담 기록" },
      ],
      image: { file: "/seed/caps/sena-kakao-team.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 3,
      relatedSlugs: ["memo-presentation-script"],
    },
    {
      slug: "dacon-contest",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "데이콘 경진대회 일정",
      ocrText: "데이콘 AI 경진대회 — 기획서 7/7 마감 · 최종 산출물 7/15 마감",
      category: "커리어",
      summary: "데이콘 AI 경진대회 — 최종 산출물 7/15 마감. 기획서는 제출 완료.",
      instances: [
        {
          intentType: "schedule",
          label: "데이콘 산출물 마감",
          payload: { title: "데이콘 최종 산출물 제출", dateInDays: 8 },
        },
        {
          intentType: "todo",
          label: "모델 성능 정리",
          payload: { title: "데이콘 제출물 정리", deadlineInDays: 8 },
        },
      ],
      image: {
        file: "/seed/caps/112ac1c74352f2b73e89a8e93845ad99887e1ae5d91467a378277ca6e557ed57.jpg",
        width: 1170,
        height: 380,
      },
      capturedDaysAgo: 18,
      favorite: true,
    },
    {
      slug: "boj-problem",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "백준 1로 만들기 2",
      url: "https://www.acmicpc.net/problem/12852",
      text: "DP 기본 문제 — 스터디 이번 주 과제",
      category: "학교·스터디",
      summary: "알고리즘 스터디 이번 주 문제 — DP 역추적. 풀고 가야 함.",
      instances: [
        {
          intentType: "todo",
          label: "스터디 문제 풀기",
          payload: {
            title: "백준 12852 풀기",
            deadlineInDays: 3,
            url: "https://www.acmicpc.net/problem/12852",
          },
        },
      ],
      capturedDaysAgo: 6,
    },
    {
      slug: "python-error",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "asyncio RuntimeError 해결법",
      ocrText:
        "RuntimeError: This event loop is already running — Jupyter에서는 nest_asyncio.apply() 또는 await 직접 사용",
      category: "개발 지식",
      summary:
        "Jupyter에서 asyncio 이벤트 루프 중복 실행 에러 — nest_asyncio 적용 또는 top-level await로 해결.",
      instances: [
        {
          intentType: "knowledge",
          label: "asyncio 에러 해결",
          payload: { topic: "Python asyncio" },
        },
      ],
      image: { file: "/seed/caps/sena-python-error.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 12,
    },
    {
      slug: "dns-note",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "DNS는 어떻게 동작하나",
      ocrText:
        "DNS 계층 구조 — 루트 → TLD → 권한 네임서버. 재귀 질의와 반복 질의의 차이, 캐시 TTL.",
      category: "개발 지식",
      summary: "DNS 계층 구조와 질의 과정 정리 — 네트워크 기말 대비 저장.",
      instances: [
        {
          intentType: "knowledge",
          label: "DNS 동작 원리",
          payload: { topic: "네트워크" },
        },
      ],
      image: {
        file: "/seed/caps/4c48a50fd944b924b2324ba7fc9080af0416f774e469b06e7fac87d06314c131.jpg",
        width: 888,
        height: 1920,
      },
      capturedDaysAgo: 25,
    },
    // ── AI 에이전트 학습 클러스터 (지난주 3건 — 채팅 시나리오의 근거) ──
    {
      slug: "youtube-langchain",
      kind: "url",
      channel: "youtube",
      source: "YouTube",
      title: "LangChain으로 AI 에이전트 만들기 — 입문 강의",
      url: "https://www.youtube.com/results?search_query=langchain+agent+tutorial",
      text: "에이전트 루프(계획→도구 호출→관찰)를 40분 만에 훑는 강의",
      userMemo: "졸업 프로젝트 참고용",
      category: "AI 학습",
      summary:
        "LangChain 에이전트 입문 강의 — 계획→도구 호출→관찰 루프, 실습 코드 링크 포함. 졸업 프로젝트 참고용으로 저장.",
      instances: [
        {
          intentType: "knowledge",
          label: "LangChain 에이전트 강의",
          payload: { topic: "AI 에이전트" },
        },
      ],
      image: {
        file: "/seed/caps/sena-youtube-langchain.jpg",
        width: 780,
        height: 1688,
      },
      capturedDaysAgo: 5,
      relatedSlugs: ["blog-rag-intro", "newsletter-agents"],
      favorite: true,
    },
    {
      slug: "blog-rag-intro",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "RAG 구조 한 번에 이해하기",
      url: "https://python.langchain.com/docs/tutorials/rag/",
      text: "검색 증강 생성 — 인덱싱(로드·분할·임베딩)과 검색·생성 두 단계",
      category: "AI 학습",
      summary:
        "RAG 파이프라인 정리 — 인덱싱(로드→분할→임베딩→저장)과 런타임(검색→생성) 두 축. 졸프 검색 기능 설계 참고.",
      instances: [
        {
          intentType: "knowledge",
          label: "RAG 구조",
          payload: { topic: "AI 에이전트", url: "https://python.langchain.com/docs/tutorials/rag/" },
        },
      ],
      capturedDaysAgo: 7,
      relatedSlugs: ["youtube-langchain", "newsletter-agents"],
    },
    {
      slug: "newsletter-agents",
      kind: "url",
      channel: "appShareSheet",
      source: "공유",
      title: "이번 주 AI 에이전트 동향 뉴스레터",
      url: "https://www.anthropic.com/research",
      text: "멀티 에이전트 협업, 도구 사용 벤치마크, 평가 프레임워크 소식",
      category: "AI 학습",
      summary:
        "AI 에이전트 주간 동향 — 멀티 에이전트 협업 사례와 도구 사용 벤치마크. 졸프 관련 레퍼런스 후보.",
      instances: [
        {
          intentType: "knowledge",
          label: "에이전트 동향",
          payload: { topic: "AI 에이전트" },
        },
      ],
      capturedDaysAgo: 6,
      relatedSlugs: ["youtube-langchain", "blog-rag-intro"],
    },
    // ── 커리어 ──────────────────────────────
    {
      slug: "intern-notice",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "여름 체험형 인턴 모집 공고",
      url: "https://www.wanted.co.kr/wdlist/518",
      text: "백엔드 개발 체험형 인턴 — 서류 마감 7/17, 자소서 2문항",
      category: "커리어",
      summary: "백엔드 체험형 인턴 공고 — 서류 마감 7/17. 자소서 2문항 준비 필요.",
      instances: [
        {
          intentType: "todo",
          label: "인턴 서류 제출",
          payload: { title: "인턴 자소서 쓰고 제출", deadlineInDays: 10 },
        },
      ],
      capturedDaysAgo: 2,
    },
    {
      slug: "contest-poster",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "교내 창업 아이디어 공모전",
      ocrText:
        "제10회 교내 창업 아이디어 공모전 — 접수 7/27까지, 팀 단위(1~4인), 총상금 500만원",
      category: "커리어",
      summary: "교내 창업 공모전 — 접수 7/27 마감, 1~4인 팀. 팀플 주제 확장해서 낼지 고민.",
      instances: [
        {
          intentType: "schedule",
          label: "공모전 접수 마감",
          payload: { title: "창업 공모전 접수 마감", dateInDays: 20 },
        },
      ],
      image: { file: "/seed/caps/sena-contest.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 8,
    },
    {
      slug: "student-loan",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "학자금 이자 납부",
      ocrText: "학자금 대출 이자 납부 안내 — 납부 기한 6월 19일",
      category: "생활·금융",
      summary: "학자금 대출 이자 납부 — 기한 내 납부 완료.",
      instances: [
        {
          intentType: "todo",
          label: "이자 납부",
          done: true,
          payload: { title: "학자금 이자 납부", deadlineInDays: -18 },
        },
      ],
      image: {
        file: "/seed/caps/618978bcb719dc7e70d3c391cbb29f7bda8c39b8f1f0e098a285d7e2b9688a2b.jpg",
        width: 888,
        height: 1920,
      },
      capturedDaysAgo: 22,
    },
    // ── 생활 ──────────────────────────────
    {
      slug: "concert-ticketing",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "여름 페스티벌 티켓 오픈",
      ocrText: "SUMMER SOUND 2026 — 1차 티켓 오픈 7/9(목) 20:00, 인터파크 단독",
      category: "일상·문화",
      summary: "여름 페스티벌 1차 티켓팅 — 7/9(목) 20:00 오픈. 알림 맞춰둘 것.",
      instances: [
        {
          intentType: "schedule",
          label: "티켓 오픈",
          payload: { title: "페스티벌 티켓팅", dateInDays: 2, time: "20:00" },
        },
      ],
      image: { file: "/seed/caps/sena-ticketing.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 1,
    },
    {
      slug: "club-mt",
      kind: "screenshot",
      channel: "kakaoTalk",
      source: "카카오톡",
      title: "동아리 여름 MT 공지",
      ocrText:
        "[중앙동아리] 여름 MT — 7/19(일)~20(월) 가평. 회비 45,000원, 참석 투표는 이번 주까지!",
      category: "일상·모임",
      summary: "동아리 MT 7/19~20 가평 — 회비 4.5만원, 참석 투표 이번 주까지.",
      instances: [
        {
          intentType: "schedule",
          label: "동아리 MT",
          payload: { title: "동아리 여름 MT (가평)", dateInDays: 12, note: "회비 45,000원" },
        },
        {
          intentType: "todo",
          label: "참석 투표",
          payload: { title: "MT 참석 투표하기", deadlineInDays: 4 },
        },
      ],
      image: { file: "/seed/caps/sena-kakao-mt.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 5,
    },
    {
      slug: "office-hour",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "교수님 면담",
      text: "금요일 2시 졸업 프로젝트 중간 점검 면담. 진행 상황 슬라이드 3장 준비.",
      category: "학교·졸프",
      summary: "졸프 중간 점검 면담 — 금요일 14:00, 진행 상황 슬라이드 3장 준비.",
      instances: [
        {
          intentType: "schedule",
          label: "졸프 면담",
          payload: { title: "교수님 졸프 면담", dateInDays: 3, time: "14:00" },
        },
        {
          intentType: "todo",
          label: "면담 슬라이드",
          payload: { title: "진행 상황 슬라이드 3장", deadlineInDays: 3 },
        },
      ],
      capturedDaysAgo: 4,
    },
    {
      slug: "notion-portfolio",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "개발자 포트폴리오 노션 템플릿",
      url: "https://www.notion.com/templates/category/portfolio",
      text: "프로젝트 카드형 정리 + 이력 타임라인 템플릿 모음",
      category: "커리어",
      summary: "포트폴리오 노션 템플릿 모음 — 인턴 지원 전에 프로젝트 정리할 때 쓸 것.",
      instances: [
        {
          intentType: "knowledge",
          label: "포트폴리오 템플릿",
          payload: { topic: "커리어 준비" },
        },
      ],
      capturedDaysAgo: 15,
    },
    {
      slug: "workout-routine",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "아침 운동 루틴",
      text: "기상 후 스트레칭 10분 → 러닝 20분 → 샤워. 주 3회만 지켜도 성공.",
      category: "일상·건강",
      summary: "아침 운동 루틴 메모 — 스트레칭 10분, 러닝 20분, 주 3회 목표.",
      instances: [{ intentType: "memo", label: "운동 루틴" }],
      capturedDaysAgo: 10,
    },
    {
      slug: "summer-class",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "계절학기 수강신청",
      text: "확률과통계 계절학기 — 수강신청 7/16 오전 10시. 서버 열리자마자 잡아야 함.",
      category: "학교·수강",
      summary: "계절학기(확률과통계) 수강신청 — 7/16 10:00 오픈.",
      instances: [
        {
          intentType: "schedule",
          label: "수강신청",
          payload: { title: "계절학기 수강신청", dateInDays: 9, time: "10:00" },
        },
      ],
      capturedDaysAgo: 7,
    },
    {
      slug: "study-schedule-change",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "스터디 시간 변경",
      text: "알고리즘 스터디 목요일 7시 → 토요일 오전 10시로 변경. 장소는 그대로 중도 스터디룸.",
      category: "학교·스터디",
      summary: "알고리즘 스터디가 토요일 10:00으로 변경 — 장소는 중앙도서관 스터디룸.",
      instances: [{ intentType: "memo", label: "스터디 변경 기록" }],
      capturedDaysAgo: 7,
    },
    {
      slug: "food-list",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "종강하면 갈 맛집",
      text: "학교 앞 마라탕 신상 / 연남동 파스타 오마카세 / 성수 베이글 — 지우랑 가기로 함.",
      category: "일상",
      summary: "종강 기념 맛집 리스트 — 마라탕·파스타·베이글. 지우와 약속.",
      instances: [{ intentType: "memo", label: "맛집 리스트" }],
      capturedDaysAgo: 20,
    },
  ],
  recall: [
    {
      itemSlug: "youtube-langchain",
      kind: "fadingValue",
      oneline: "저장한 지 5일, 아직 안 열어보셨어요",
      gist: ["에이전트 루프: 계획→도구 호출→관찰", "실습 코드 링크 포함", "졸프 참고용으로 담아두셨어요"],
    },
    {
      itemSlug: "blog-rag-intro",
      kind: "relatedCluster",
      oneline: "AI 에이전트 기록이 일주일 새 세 개 모였어요",
      gist: ["RAG 구조 + 강의 + 동향 뉴스레터", "졸업 프로젝트 검색 기능과 이어져요"],
    },
    {
      itemSlug: "lms-os-assignment",
      kind: "linkedToRecent",
      oneline: "어제 남긴 발표 대본 메모와 같은 주 마감이에요",
      gist: ["과제 4 제출 7/12(일) 23:59", "지연 제출은 일당 10% 감점"],
    },
    {
      itemSlug: "dns-note",
      kind: "fadingValue",
      oneline: "기말 대비로 담아둔 지 한 달 가까이 됐어요",
      gist: ["DNS 계층 구조와 질의 과정", "재귀 질의 vs 반복 질의"],
    },
    {
      itemSlug: "dacon-contest",
      kind: "revisitedOften",
      oneline: "이번 주에만 세 번 열어보셨어요",
      gist: ["최종 산출물 7/15 마감", "모델 성능 정리가 남아 있어요"],
    },
  ],
  cannedChat: senaChat,
  cannedSearch: senaSearch,
};

export default sena;
