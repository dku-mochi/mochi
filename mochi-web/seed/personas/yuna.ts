import type { SeedPersona } from "../schema";
import { yunaChat, yunaSearch } from "../canned/yuna";

/*
 * 이유나 — 26, 콘텐츠 마케터.
 * 페인포인트: 스크린샷을 왜 찍었는지 기억이 안 난다 (PRODUCT.md §2.1).
 * intent 무게중심: 기록(memo). 서사 축:
 *  1) 성수 카페 클러스터 — 인스타 캡처 3건 (relatedCluster)
 *  2) 리넨 원피스 위시리스트 — "지난주에 본 그 원피스" 검색·채팅 시나리오
 *  3) 엄마 생신 선물 + 전시 예매 — 생활 마감
 * 이미지: 실DB 캡처 1장(남양주) + 목업 캡처 8장.
 */
const yuna: SeedPersona = {
  slug: "yuna",
  name: "이유나",
  age: 26,
  job: "콘텐츠 마케터",
  tagline: "스크린샷은 쌓이는데, 왜 찍었는지 기억이 안 나요",
  intro:
    "감도 좋은 것들을 부지런히 캡처해요. 문제는 앨범 3천 장 속에서 다시 만나지 못한다는 것.",
  uuidEnvKey: "MOCHI_PERSONA_UUID_YUNA",
  accent: "blush",
  heroSlugs: ["insta-cafe-window", "shop-linen-dress", "exhibition-booking"],
  suggestedSearch: [
    "봐둔 린넨 원피스",
    "성수 카페 모아둔 것",
    "엄마 생신 선물",
  ],
  suggestedChat: [
    "캡처해둔 원피스 어디 거였지?",
    "주말에 갈 만한 곳 저장해둔 것 중에 추천해줘",
  ],
  items: [
    // ── 성수 카페 클러스터 ──────────
    {
      slug: "insta-cafe-bakery",
      kind: "screenshot",
      channel: "instagram",
      source: "Instagram",
      title: "성수 소금빵 베이커리",
      ocrText:
        "@seongsu.bakery 오전에만 굽는 소금빵, 11시 전 방문 추천 - 성수역 3번 출구 도보 5분",
      category: "장소·카페",
      summary: "성수 소금빵 베이커리예요. 소금빵이 오전 한정이라 11시 전에 가는 게 좋아요.",
      instances: [{ intentType: "memo", label: "가고 싶은 카페" }],
      image: { file: "/seed/caps/yuna-cafe-bakery.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 4,
      relatedSlugs: ["insta-cafe-window", "insta-cafe-brunch"],
    },
    {
      slug: "insta-cafe-window",
      kind: "screenshot",
      channel: "instagram",
      source: "Instagram",
      title: "창가 자리가 예쁜 성수 카페",
      ocrText:
        "@cafe.windowseat 통창으로 서울숲 뷰 - 평일 오후가 한산해요. 라떼 맛집",
      category: "장소·카페",
      summary: "서울숲 통창 뷰 카페예요. 평일 오후가 한산하고, 라떼가 추천 메뉴예요.",
      instances: [{ intentType: "memo", label: "가고 싶은 카페" }],
      image: { file: "/seed/caps/yuna-cafe-window.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 7,
      relatedSlugs: ["insta-cafe-bakery", "insta-cafe-brunch"],
      favorite: true,
    },
    {
      slug: "insta-cafe-brunch",
      kind: "screenshot",
      channel: "instagram",
      source: "Instagram",
      title: "주말 브런치 되는 성수 카페",
      ocrText:
        "@brunch.seongsu 주말 브런치 11:00–15:00, 리코타 토스트 시그니처. 웨이팅 30분 각오",
      category: "장소·카페",
      summary: "성수 브런치 카페예요. 브런치는 주말 11~15시, 리코타 토스트가 대표 메뉴예요. 웨이팅은 있는 편이에요.",
      instances: [{ intentType: "memo", label: "가고 싶은 카페" }],
      image: { file: "/seed/caps/yuna-cafe-brunch.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 12,
      relatedSlugs: ["insta-cafe-bakery", "insta-cafe-window"],
    },
    // ── 쇼핑·위시리스트 ──────────
    {
      slug: "shop-linen-dress",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "리넨 미디 원피스",
      ocrText:
        "린넨 라이크 미디 원피스 - 크림·세이지 2색, 89,000원. 7/10까지 여름 프리오더 10% 쿠폰",
      category: "쇼핑",
      summary:
        "리넨 미디 원피스예요. 크림·세이지 두 색에 8.9만원, 프리오더 10% 쿠폰은 7/10까지예요.",
      instances: [
        { intentType: "memo", label: "위시리스트" },
        {
          intentType: "todo",
          label: "쿠폰 마감 전 결정",
          payload: { title: "원피스 살지 결정", deadlineInDays: 3 },
        },
      ],
      image: { file: "/seed/caps/yuna-dress.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 6,
      favorite: true,
    },
    // ── 생활 마감 ──────────
    {
      slug: "gift-mom",
      kind: "memo",
      channel: "appIntent",
      source: "백탭 메모",
      title: "엄마 생신 선물",
      text: "엄마 생신 7/18. 선물 후보: 실크 스카프, 홍삼 스틱, 호텔 애프터눈티. 배송 생각하면 7/14까지 주문.",
      category: "가족",
      summary:
        "엄마 생신(7/18) 선물 후보예요. 스카프·홍삼·애프터눈티 중에서 고르고, 주문은 7/14까지 해야 해요.",
      instances: [
        {
          intentType: "schedule",
          label: "엄마 생신",
          payload: { title: "엄마 생신", dateInDays: 11 },
        },
        {
          intentType: "todo",
          label: "선물 주문",
          payload: { title: "생신 선물 주문", deadlineInDays: 7 },
        },
      ],
      capturedDaysAgo: 3,
    },
    {
      slug: "exhibition-booking",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "빛의 정원 미디어아트展 예매 오픈",
      ocrText:
        "《빛의 정원》 미디어아트 - 2차 예매 7/10(금) 14:00 오픈. 주말 회차 조기 매진 예상",
      category: "문화·전시",
      summary: "미디어아트 전시 2차 예매가 7/10(금) 14:00에 열려요. 주말 회차는 서둘러야 해요.",
      instances: [
        {
          intentType: "schedule",
          label: "전시 예매 오픈",
          payload: { title: "빛의 정원 예매", dateInDays: 3, time: "14:00" },
        },
      ],
      image: { file: "/seed/caps/yuna-exhibition.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 2,
      relatedSlugs: ["brand-reference"],
    },
    {
      slug: "recipe-reel",
      kind: "url",
      channel: "instagram",
      source: "Instagram",
      title: "원팬 토마토 파스타 릴스",
      url: "https://www.instagram.com/explore/tags/onepanpasta/",
      text: "팬 하나로 끝내는 토마토 파스타 - 면수 조절이 포인트",
      userMemo: "주말에 해먹기",
      category: "요리",
      summary: "원팬 토마토 파스타 레시피예요. 면수 조절이 핵심이에요. 주말 요리 후보로 담아뒀어요.",
      instances: [
        {
          intentType: "knowledge",
          label: "파스타 레시피",
          payload: { topic: "요리" },
        },
      ],
      capturedDaysAgo: 15,
    },
    // ── 일·레퍼런스 ──────────
    {
      slug: "brand-reference",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "팝업스토어 공간 레퍼런스",
      ocrText:
        "F/W 팝업 '방의 기록' - 아카이브 선반 연출, 입장 동선에 향 경험 배치. 체류시간 평균 23분",
      category: "일·레퍼런스",
      summary:
        "팝업스토어 레퍼런스예요. 아카이브 선반과 향 경험 동선으로 체류 23분을 만들었어요. 다음 캠페인에 참고하기 좋아요.",
      instances: [
        {
          intentType: "knowledge",
          label: "팝업 레퍼런스",
          payload: { topic: "브랜드 캠페인" },
        },
      ],
      image: { file: "/seed/caps/yuna-popup.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 1,
      relatedSlugs: ["exhibition-booking", "campaign-meeting"],
    },
    {
      slug: "campaign-meeting",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "8월 캠페인 회의 결정",
      text: "8월 캠페인 컨셉 '여름의 끝 기록하기'로 확정. 숏폼 3편 + 팝업 연계. 카피 시안은 다음 주 수요일까지.",
      category: "일·캠페인",
      summary:
        "8월 캠페인 '여름의 끝 기록하기'가 확정됐어요. 숏폼 3편과 팝업 연계, 카피 시안은 다음 주 수요일까지예요.",
      instances: [
        { intentType: "memo", label: "회의 결정 기록" },
        {
          intentType: "todo",
          label: "카피 시안",
          payload: { title: "캠페인 카피 시안", deadlineInDays: 8 },
        },
      ],
      capturedDaysAgo: 2,
    },
    // ── 일상 기록 ──────────
    {
      slug: "book-quote",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "밑줄 그은 문장",
      ocrText:
        "\"기록은 기억을 대신하지 않는다. 기억이 돌아올 자리를 마련해 둘 뿐이다.\" - 『기록의 쓸모』",
      category: "책·문장",
      summary: "『기록의 쓸모』에서 밑줄 그은 문장이에요. '기록은 기억이 돌아올 자리를 마련한다.'",
      instances: [{ intentType: "memo", label: "문장 수집" }],
      image: { file: "/seed/caps/yuna-book.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 9,
    },
    {
      slug: "wedding-invitation",
      kind: "screenshot",
      channel: "kakaoTalk",
      source: "카카오톡",
      title: "수민이 결혼식 청첩장",
      ocrText:
        "김수민 ♥ 이준호 - 7/20(월) 12:30, 더채플앳청담. 모바일 청첩장",
      category: "일상·모임",
      summary: "수민이 결혼식이 7/20(월) 12:30 더채플앳청담에서 있어요.",
      instances: [
        {
          intentType: "schedule",
          label: "결혼식",
          payload: { title: "수민이 결혼식", dateInDays: 13, time: "12:30" },
        },
      ],
      image: { file: "/seed/caps/yuna-wedding.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 5,
    },
    {
      slug: "hair-salon",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "미용실 예약",
      text: "일요일 오후 1시 미용실. 이번엔 애쉬브라운 톤 다운, 레퍼런스 사진 보여주기.",
      category: "생활·뷰티",
      summary: "미용실 예약이 일요일 13:00에 있어요. 애쉬브라운으로 톤 다운할 예정이에요.",
      instances: [
        {
          intentType: "schedule",
          label: "미용실",
          payload: { title: "미용실 예약", dateInDays: 5, time: "13:00" },
        },
      ],
      capturedDaysAgo: 2,
    },
    {
      slug: "pilates",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "필라테스 시간 변경",
      text: "다음 달부터 화·목 저녁 7시 → 아침 7시 반으로 변경. 아침에 하고 출근하는 게 낫다.",
      category: "생활·건강",
      summary: "필라테스가 다음 달부터 화·목 아침 7:30으로 바뀌어요.",
      instances: [{ intentType: "memo", label: "루틴 변경 기록" }],
      capturedDaysAgo: 8,
    },
    {
      slug: "jeju-stay",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "제주 조천읍 돌집 스테이",
      url: "https://www.airbnb.co.kr/s/제주/homes",
      text: "8월 휴가 후보 - 마당 있는 돌집, 2박 기준 26만원. 8월 둘째 주 비어 있음",
      category: "여행",
      summary: "8월 휴가 숙소 후보예요. 제주 조천 돌집 스테이, 2박 26만원이에요.",
      instances: [{ intentType: "memo", label: "휴가 숙소 후보" }],
      capturedDaysAgo: 10,
    },
    {
      slug: "namyangju-trip",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "남양주 여행",
      ocrText: "남양주 당일치기 - 물의정원 → 카페거리 → 정약용 유적지. 친구들과 6/26–27",
      category: "여행",
      summary: "지난달 남양주 여행 코스 기록이에요. 물의정원과 카페거리를 다녀왔어요.",
      instances: [
        {
          intentType: "schedule",
          label: "남양주 여행",
          payload: { title: "남양주 여행", dateInDays: -11 },
        },
        { intentType: "memo", label: "여행 기록" },
      ],
      image: {
        file: "/seed/caps/bb0a20f05d016cae2140ec5268019a4bb8d428c46799615ef97a5bc8d9fd4bf0.jpg",
        width: 888,
        height: 1920,
      },
      capturedDaysAgo: 21,
    },
    {
      slug: "honeycombo-video",
      kind: "url",
      channel: "youtube",
      source: "YouTube",
      title: "허니콤보 공짜로 받는 법",
      url: "https://www.youtube.com/results?search_query=치킨+스탬프+앱",
      text: "스탬프 적립 앱 소개 영상 - 치킨 브랜드별 리워드 비교",
      category: "일상",
      summary: "치킨 스탬프 적립 앱을 소개하는 영상이에요. 브랜드별 리워드를 비교해줘요.",
      instances: [{ intentType: "memo", label: "생활 꿀팁" }],
      capturedDaysAgo: 23,
    },
    {
      slug: "movie-list",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "이번 달 볼 영화",
      text: "리스트: 재개봉 <이터널 선샤인>, 신작 애니 하나, 왓챠에 올라온 다큐 <바다의 기억>.",
      category: "문화·영화",
      summary: "7월 영화 리스트 - 이터널 선샤인 재개봉 외 2편.",
      instances: [{ intentType: "memo", label: "볼 영화" }],
      capturedDaysAgo: 14,
    },
    {
      slug: "budget-rule",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "월급 배분 규칙",
      text: "월급날 자동이체: 저축 40 / 생활 40 / 즐거움 20. 즐거움 계좌 바닥나면 그 달은 끝.",
      category: "생활·금융",
      summary: "월급 배분 40/40/20 규칙 - 즐거움 계좌 소진 시 지출 중단.",
      instances: [{ intentType: "memo", label: "돈 규칙" }],
      capturedDaysAgo: 30,
    },
    {
      slug: "flower-class",
      kind: "screenshot",
      channel: "instagram",
      source: "Instagram",
      title: "여름 플라워 원데이클래스",
      ocrText:
        "@flower.atelier 7월 원데이클래스 - 7/16(목) 19:30 여름 꽃다발. 4인 소규모, DM 예약",
      category: "취미",
      summary: "플라워 원데이클래스 - 7/16(목) 19:30, 4인 소규모 DM 예약.",
      instances: [
        {
          intentType: "schedule",
          label: "원데이클래스",
          payload: { title: "플라워 클래스", dateInDays: 9, time: "19:30" },
        },
      ],
      image: { file: "/seed/caps/yuna-flower.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 4,
    },
  ],
  recall: [
    {
      itemSlug: "insta-cafe-window",
      kind: "relatedCluster",
      oneline: "성수 카페 기록이 세 곳 모였어요",
      gist: ["소금빵·통창 뷰·브런치", "이번 주말 코스로 묶기 좋아요"],
    },
    {
      itemSlug: "shop-linen-dress",
      kind: "revisitedOften",
      oneline: "이번 주에 두 번 다시 보셨어요 - 결정하셨어요?",
      gist: ["크림·세이지 2색, 89,000원", "프리오더 10% 쿠폰이 곧 끝나요"],
    },
    {
      itemSlug: "recipe-reel",
      kind: "fadingValue",
      oneline: "'주말에 해먹기'라고 적어둔 지 2주째예요",
      gist: ["원팬 토마토 파스타", "면수 조절이 포인트"],
    },
    {
      itemSlug: "exhibition-booking",
      kind: "linkedToRecent",
      oneline: "어제 담은 팝업 레퍼런스와 결이 이어져요",
      gist: ["2차 예매 7/10(금) 14:00", "주말 회차 조기 매진 예상"],
    },
  ],
  cannedChat: yunaChat,
  cannedSearch: yunaSearch,
};

export default yuna;
