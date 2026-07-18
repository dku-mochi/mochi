import type { PlaceWire } from "@/lib/api/wire";
import type { SeedPersona } from "@seed/schema";

export interface CaptureExampleImage {
  file: string;
  width: number;
  height: number;
}

interface CaptureExampleBase {
  id: string;
  title: string;
  /** 장소 예시는 분석 폴백에서도 상세 지도 계약을 잃지 않는다. */
  place?: PlaceWire;
}

export type CaptureExample =
  | (CaptureExampleBase & { kind: "screenshot"; image: CaptureExampleImage })
  | (CaptureExampleBase & {
      kind: "url";
      url: string;
      image: CaptureExampleImage;
    })
  | (CaptureExampleBase & { kind: "memo"; text: string });

type ScreenshotExample = Extract<CaptureExample, { kind: "screenshot" }>;

interface CuratedPlaceExample {
  slug: string;
  title: string;
  text: string;
  place: PlaceWire;
}

const naverMapUrl = (name: string) =>
  `https://map.naver.com/p/search/${encodeURIComponent(name)}`;

const PLACE_EXAMPLES: Record<string, CuratedPlaceExample[]> = {
  sena: [
    {
      slug: "dankook-ai-cloud",
      title: "AWS AI·클라우드 특화교육",
      text: "7월 20~24일 단국대 죽전캠퍼스에서 열리는 실무 맞춤형 AI·클라우드 특화교육.",
      place: {
        name: "단국대학교 소프트웨어ICT관",
        lat: 37.3216,
        lng: 127.1267,
        category: "대학교",
        roadAddress: "경기 용인시 수지구 죽전로 152 소프트웨어ICT관 206호",
        mapUrl: naverMapUrl("단국대학교 소프트웨어ICT관"),
      },
    },
    {
      slug: "gogiri-makguksu",
      title: "웨이팅 필수 고기리막국수",
      text: "용인에서 저장한 고기리막국수. 들기름막국수와 비빔막국수를 먹어보기.",
      place: {
        name: "고기리막국수",
        lat: 37.3505,
        lng: 127.0659,
        category: "막국수",
        roadAddress: "경기 용인시 수지구 이종무로 157",
        mapUrl: naverMapUrl("고기리막국수"),
      },
    },
    {
      slug: "hongchun-yongin",
      title: "용인 웨이팅 맛집 홍춘",
      text: "해물짬뽕으로 유명한 용인 홍춘. 붐비기 전에 일찍 가기.",
      place: {
        name: "홍춘",
        lat: 37.3245,
        lng: 127.128,
        category: "중식당",
        roadAddress: "경기 용인시 수지구 죽전로168번길 29 1층",
        mapUrl: naverMapUrl("용인 홍춘"),
      },
    },
    {
      slug: "edc-korea-inspire",
      title: "EDC 코리아 2026",
      text: "10월 3~4일 인천 인스파이어 엔터테인먼트 리조트에서 열리는 EDC 코리아.",
      place: {
        name: "인스파이어 엔터테인먼트 리조트",
        lat: 37.4626,
        lng: 126.3896,
        category: "복합리조트",
        roadAddress: "인천 중구 공항문화로 127",
        mapUrl: naverMapUrl("인스파이어 엔터테인먼트 리조트"),
      },
    },
    {
      slug: "central-library-study",
      title: "중앙도서관 스터디룸",
      text: "토요일 오전 10시 알고리즘 스터디. 중앙도서관 스터디룸에서 만나기.",
      place: {
        name: "서울대학교 중앙도서관",
        lat: 37.4599,
        lng: 126.9519,
        category: "도서관",
        roadAddress: "서울 관악구 관악로 1",
        mapUrl: naverMapUrl("서울대학교 중앙도서관"),
      },
    },
    {
      slug: "gapyeong-mt",
      title: "동아리 MT 집결지",
      text: "8월 22일 동아리 MT. 오전 10시까지 가평역 1번 출구에서 만나기.",
      place: {
        name: "가평역",
        lat: 37.8146,
        lng: 127.5108,
        category: "기차역",
        roadAddress: "경기 가평군 가평읍 문화로 13-42",
        mapUrl: naverMapUrl("가평역"),
      },
    },
    {
      slug: "hongdae-concert",
      title: "공연 전 홍대 약속 장소",
      text: "공연 시작 한 시간 전 KT&G 상상마당 홍대 앞에서 지우 만나기.",
      place: {
        name: "KT&G 상상마당 홍대",
        lat: 37.5509,
        lng: 126.921,
        category: "복합문화공간",
        roadAddress: "서울 마포구 어울마당로 65",
        mapUrl: naverMapUrl("KT&G 상상마당 홍대"),
      },
    },
    {
      slug: "sharosu-campus-meal",
      title: "샤로수길 덮밥집",
      text: "공강날 혼밥할 샤로수길 덮밥집. 점심 웨이팅은 15분 정도라 11시 40분에 가기.",
      place: {
        name: "샤로수길",
        lat: 37.4799,
        lng: 126.9523,
        category: "맛집거리",
        roadAddress: "서울 관악구 관악로14길 일대",
        mapUrl: naverMapUrl("샤로수길"),
      },
    },
    {
      slug: "mangwon-market-food",
      title: "망원시장 먹거리",
      text: "주말 망원시장 먹거리 코스. 닭강정부터 사고 고로케와 꽈배기는 포장하기.",
      place: {
        name: "망원시장",
        lat: 37.556,
        lng: 126.9058,
        category: "전통시장",
        roadAddress: "서울 마포구 포은로8길 14",
        mapUrl: naverMapUrl("망원시장"),
      },
    },
  ],
  dohyun: [
    {
      slug: "yangwoojung-pangyo",
      title: "판교 회식 맛집 양우정",
      text: "특양구이와 한우대창구이를 함께 먹을 수 있는 판교 양우정 회식 후보.",
      place: {
        name: "양우정",
        lat: 37.4001,
        lng: 127.111,
        category: "곱창",
        roadAddress: "경기 성남시 분당구 대왕판교로606번길 10",
        mapUrl: naverMapUrl("판교 양우정"),
      },
    },
    {
      slug: "pangyo-dinorun",
      title: "판교 공룡런 5km 코스",
      text: "금토천에서 화랑공원과 판교테크노파크를 지나 봇들저류지공원까지 도는 5km 코스.",
      place: {
        name: "화랑공원",
        lat: 37.3973,
        lng: 127.1158,
        category: "근린공원",
        roadAddress: "경기 성남시 분당구 대왕판교로 609",
        mapUrl: naverMapUrl("판교 화랑공원"),
      },
    },
    {
      slug: "pangyo-team-dinner",
      title: "판교역 팀 회식",
      text: "다음 주 금요일 저녁 7시 팀 회식. 판교역 1번 출구에서 모여 양꼬치집으로 이동.",
      place: {
        name: "판교역",
        lat: 37.3948,
        lng: 127.1112,
        category: "지하철역",
        roadAddress: "경기 성남시 분당구 판교역로 160",
        mapUrl: naverMapUrl("판교역"),
      },
    },
    {
      slug: "gangnam-tech-books",
      title: "DDIA 실물 확인할 서점",
      text: "퇴근길에 교보문고 강남점에서 데이터 중심 애플리케이션 설계 개정판 확인하기.",
      place: {
        name: "교보문고 강남점",
        lat: 37.5039,
        lng: 127.0243,
        category: "서점",
        roadAddress: "서울 서초구 강남대로 465",
        mapUrl: naverMapUrl("교보문고 강남점"),
      },
    },
    {
      slug: "yangjae-run",
      title: "주말 러닝 코스",
      text: "토요일 아침 양재시민의숲에서 5km 러닝. 매헌역 쪽 입구에서 시작하기.",
      place: {
        name: "양재시민의숲",
        lat: 37.4705,
        lng: 127.035,
        category: "도시공원",
        roadAddress: "서울 서초구 매헌로 99",
        mapUrl: naverMapUrl("양재시민의숲"),
      },
    },
    {
      slug: "pangyo-team-lunch",
      title: "판교 점심 회식 후보",
      text: "팀 점심 회식 후보. 현대백화점 판교점 식당가에서 6인 룸 예약 가능한 곳 확인하기.",
      place: {
        name: "현대백화점 판교점",
        lat: 37.3928,
        lng: 127.112,
        category: "백화점",
        roadAddress: "경기 성남시 분당구 판교역로146번길 20",
        mapUrl: naverMapUrl("현대백화점 판교점"),
      },
    },
    {
      slug: "coex-pycon",
      title: "PyCon Korea 행사장",
      text: "PyCon Korea 행사장. 오전 세션 전에 코엑스 그랜드볼룸 입구에서 스터디원 만나기.",
      place: {
        name: "코엑스",
        lat: 37.5126,
        lng: 127.059,
        category: "컨벤션센터",
        roadAddress: "서울 강남구 영동대로 513",
        mapUrl: naverMapUrl("코엑스"),
      },
    },
    {
      slug: "pangyo-dentist",
      title: "판교역 치과 예약",
      text: "월요일 6시 30분 스케일링. 회사에서 판교역 쪽 치과까지 20분 잡고 출발하기.",
      place: {
        name: "판교역",
        lat: 37.3948,
        lng: 127.1112,
        category: "지하철역",
        roadAddress: "경기 성남시 분당구 판교역로 160",
        mapUrl: naverMapUrl("판교역 치과"),
      },
    },
  ],
  yuna: [
    {
      slug: "betong-seongsu",
      title: "성수 소금빵 맛집 베통",
      text: "성수에서 저장한 소금빵 맛집 베통. 인기 메뉴가 품절되기 전에 들르기.",
      place: {
        name: "베통 성수",
        lat: 37.5438,
        lng: 127.0546,
        category: "베이커리",
        roadAddress: "서울 성동구 연무장7가길 8 1층",
        mapUrl: naverMapUrl("베통 성수"),
      },
    },
    {
      slug: "the-coffee-seongsu",
      title: "성수 신상 카페 더 커피",
      text: "붉은 벽돌 건물과 야외 자리가 눈에 띄는 서울숲 카페 더 커피.",
      place: {
        name: "더 커피 성수",
        lat: 37.5469,
        lng: 127.0429,
        category: "카페",
        roadAddress: "서울 성동구 서울숲2길 27 1층",
        mapUrl: naverMapUrl("더 커피 성수"),
      },
    },
    {
      slug: "coex-illustration-fair",
      title: "서울일러스트레이션페어 V.21",
      text: "7월 30일부터 8월 2일까지 코엑스 Hall C에서 열리는 일러스트레이션페어.",
      place: {
        name: "코엑스 Hall C",
        lat: 37.5126,
        lng: 127.059,
        category: "전시장",
        roadAddress: "서울 강남구 영동대로 513",
        mapUrl: naverMapUrl("코엑스 Hall C"),
      },
    },
    {
      slug: "seongsu-date-cafes",
      title: "성수 데이트 카페 4곳",
      text: "샌드위치와 프렌치토스트, 디저트를 함께 볼 수 있는 성수 데이트 카페 모음.",
      place: {
        name: "성수동 카페거리",
        lat: 37.5445,
        lng: 127.0558,
        category: "카페거리",
        roadAddress: "서울 성동구 성수동2가 일대",
        mapUrl: naverMapUrl("성수동 카페거리"),
      },
    },
    {
      slug: "new-order-club-yeonnam",
      title: "연남동 뉴오더클럽 피자",
      text: "감자튀김과 루콜라 토핑을 반반으로 고를 수 있는 연남동 뉴오더클럽 피자.",
      place: {
        name: "뉴오더클럽 연남",
        lat: 37.5574,
        lng: 126.9251,
        category: "피자",
        roadAddress: "서울 마포구 동교로34길 3 1층",
        mapUrl: naverMapUrl("뉴오더클럽 연남"),
      },
    },
    {
      slug: "tamranun-ilsang-jeju",
      title: "제주 돌집 스테이 탐라는일상",
      text: "오래된 목조 지붕을 살려 개조한 제주 대정읍의 조용한 돌집 스테이.",
      place: {
        name: "탐라는일상",
        lat: 33.275,
        lng: 126.207,
        category: "숙소",
        roadAddress: "제주 서귀포시 대정읍 무릉인향로14번길 16",
        mapUrl: naverMapUrl("제주 탐라는일상"),
      },
    },
    {
      slug: "craft-practice-seongsu",
      title: "성수 도자기 클래스 크래프트 프랙티스",
      text: "컬러 클레이로 접시를 만드는 성수 도자기 원데이 클래스.",
      place: {
        name: "크래프트 프랙티스",
        lat: 37.547,
        lng: 127.0434,
        category: "도자기 공방",
        roadAddress: "서울 성동구 뚝섬로7길 6 3층",
        mapUrl: naverMapUrl("크래프트 프랙티스"),
      },
    },
    {
      slug: "seoul-forest-cafe",
      title: "서울숲 카페 약속",
      text: "토요일 오후 2시 서울숲 입구에서 만나 통창 카페 가기. 평일보다 붐빌 수 있음.",
      place: {
        name: "서울숲",
        lat: 37.5444,
        lng: 127.0374,
        category: "도시공원",
        roadAddress: "서울 성동구 뚝섬로 273",
        mapUrl: naverMapUrl("서울숲"),
      },
    },
    {
      slug: "mmca-exhibition",
      title: "국립현대미술관 전시",
      text: "일요일 오후 국립현대미술관 서울관 전시 보기. 삼청동 카페 코스와 묶기.",
      place: {
        name: "국립현대미술관 서울",
        lat: 37.5786,
        lng: 126.98,
        category: "미술관",
        roadAddress: "서울 종로구 삼청로 30",
        mapUrl: naverMapUrl("국립현대미술관 서울"),
      },
    },
    {
      slug: "namyangju-water-garden",
      title: "남양주 물의정원",
      text: "다음 남양주 당일치기 때 물의정원은 오전에 먼저 들르고 카페거리로 이동하기.",
      place: {
        name: "물의정원",
        lat: 37.5531,
        lng: 127.3104,
        category: "생태공원",
        roadAddress: "경기 남양주시 조안면 북한강로 398",
        mapUrl: naverMapUrl("남양주 물의정원"),
      },
    },
    {
      slug: "seongsu-bakery",
      title: "성수 소금빵 베이커리",
      text: "주말 오전 성수 소금빵 베이커리. 품절 전에 11시쯤 들르고 서울숲으로 이동하기.",
      place: {
        name: "성수동 카페거리",
        lat: 37.5445,
        lng: 127.0558,
        category: "카페거리",
        roadAddress: "서울 성동구 성수이로 일대",
        mapUrl: naverMapUrl("성수동 카페거리"),
      },
    },
    {
      slug: "yeonnam-brunch",
      title: "연남동 브런치 카페",
      text: "일요일 늦은 아침 연남동 브런치. 경의선숲길 산책 전에 테라스 자리 확인하기.",
      place: {
        name: "연남동 경의선숲길",
        lat: 37.5627,
        lng: 126.9255,
        category: "공원길",
        roadAddress: "서울 마포구 동교로41길 일대",
        mapUrl: naverMapUrl("연남동 경의선숲길"),
      },
    },
    {
      slug: "yeonnam-pizza",
      title: "연남동 화덕피자",
      text: "인스타에서 저장한 연남동 화덕피자. 테라스 자리와 라구 피자 후기를 다시 보기.",
      place: {
        name: "연남동",
        lat: 37.5609,
        lng: 126.9235,
        category: "맛집거리",
        roadAddress: "서울 마포구 연남동 일대",
        mapUrl: naverMapUrl("연남동 화덕피자"),
      },
    },
  ],
};

type ScreenshotSpec =
  | { key: string; itemSlug: string; placeSlug?: string }
  | {
      key: string;
      title: string;
      file: string;
      width?: number;
      height?: number;
      placeSlug?: string;
    };

type UrlSpec = readonly [
  key: string,
  title: string,
  url: string,
  imageKey: string,
  placeSlug?: string,
];

type MemoSpec = readonly [key: string, title: string, text: string, placeSlug?: string];

const SCREENSHOTS: Record<string, ScreenshotSpec[]> = {
  sena: [
    { key: "os-assignment", itemSlug: "lms-os-assignment" },
    { key: "library", title: "AWS AI·클라우드 특화교육", file: "sena-dankook-ai-cloud.webp", width: 780, height: 1691, placeSlug: "dankook-ai-cloud" },
    { key: "sharosu-food", title: "웨이팅 필수 고기리막국수", file: "sena-gogiri-makguksu.webp", width: 780, height: 1691, placeSlug: "gogiri-makguksu" },
    { key: "team-decision", itemSlug: "kakao-team-decision" },
    { key: "dacon", itemSlug: "dacon-contest" },
    { key: "intern", title: "핫셀러 신입 개발자 채용", file: "sena-hotseller-developer-job.webp", width: 780, height: 1691 },
    { key: "mangwon-market", title: "용인 웨이팅 맛집 홍춘", file: "sena-hongchun-yongin.webp", width: 780, height: 1691, placeSlug: "hongchun-yongin" },
    { key: "python-error", itemSlug: "python-error" },
    { key: "dns", itemSlug: "dns-note" },
    { key: "langchain", itemSlug: "youtube-langchain" },
    { key: "contest", itemSlug: "contest-poster" },
    { key: "student-loan", itemSlug: "student-loan" },
    { key: "concert", title: "EDC 코리아 2026 일정", file: "sena-edc-korea.webp", width: 780, height: 1691, placeSlug: "edc-korea-inspire" },
    { key: "club-mt", itemSlug: "club-mt", placeSlug: "gapyeong-mt" },
    { key: "office-hour", title: "교수님 오피스아워 예약", file: "sena-office-hour.png" },
  ],
  dohyun: [
    { key: "k8s", itemSlug: "k8s-cheatsheet" },
    { key: "grafana", title: "결제 API 지연 대시보드", file: "dohyun-grafana.png" },
    { key: "pangyo-lunch", title: "판교 회식 맛집 양우정", file: "dohyun-yangwoojung-pangyo.webp", width: 780, height: 1691, placeSlug: "yangwoojung-pangyo" },
    { key: "oom", itemSlug: "error-oom" },
    { key: "code-review", title: "결제 API v2 코드 리뷰", file: "dohyun-code-review.png" },
    { key: "ddia", itemSlug: "book-ddia", placeSlug: "gangnam-tech-books" },
    { key: "system-design", title: "TMUX 마스터클래스: cmux 코딩 에이전트", file: "dohyun-cmux-masterclass.webp", width: 780, height: 1691 },
    { key: "slack", itemSlug: "slack-api-migration" },
    { key: "deploy", title: "8월 정기 배포 캘린더", file: "dohyun-deploy.png" },
    { key: "postmortem", title: "8월 장애 회고 문서", file: "dohyun-postmortem.png" },
    { key: "gpu", itemSlug: "gpu-pricing" },
    { key: "pycon", title: "PyCon Korea 2026 프로젝트 쇼케이스", file: "dohyun-pycon-showcase.webp", width: 780, height: 1691 },
    { key: "team-dinner", itemSlug: "team-dinner", placeSlug: "pangyo-team-dinner" },
    { key: "dentist", title: "치과 스케일링 예약", file: "dohyun-dentist.png", placeSlug: "pangyo-dentist" },
    { key: "running", title: "판교 공룡런 5km 코스", file: "dohyun-pangyo-dinorun.webp", width: 780, height: 1691, placeSlug: "pangyo-dinorun" },
  ],
  yuna: [
    { key: "bakery", title: "성수 소금빵 맛집 베통", file: "yuna-betong-seongsu.webp", width: 780, height: 1691, placeSlug: "betong-seongsu" },
    { key: "recipe", title: "원팬 파스타 레시피 12가지", file: "yuna-onepan-pasta-12.webp", width: 780, height: 1691 },
    { key: "cafe-window", title: "성수 신상 카페 더 커피", file: "yuna-the-coffee-seongsu.webp", width: 780, height: 1691, placeSlug: "the-coffee-seongsu" },
    { key: "dress", title: "알로 요가 아이코닉 쇼퍼 토트백", file: "yuna-oversized-layered-tee.webp", width: 780, height: 1691 },
    { key: "exhibition", title: "서울일러스트레이션페어 V.21", file: "yuna-seoul-illustration-fair.webp", width: 780, height: 1691, placeSlug: "coex-illustration-fair" },
    { key: "salon", title: "애쉬브라운 톤다운 예약", file: "yuna-salon.png" },
    { key: "brunch", title: "성수 데이트 카페 4곳", file: "yuna-seongsu-date-cafes.webp", width: 780, height: 1691, placeSlug: "seongsu-date-cafes" },
    { key: "popup", itemSlug: "brand-reference" },
    { key: "yeonnam-pizza", title: "연남동 뉴오더클럽 피자", file: "yuna-new-order-club-pizza.webp", width: 780, height: 1691, placeSlug: "new-order-club-yeonnam" },
    { key: "book", itemSlug: "book-quote" },
    { key: "wedding", itemSlug: "wedding-invitation" },
    { key: "pilates", title: "화·목 아침 필라테스 일정", file: "yuna-pilates.png" },
    { key: "jeju", title: "제주 돌집 스테이 탐라는일상", file: "yuna-tamranun-ilsang-jeju.webp", width: 780, height: 1691, placeSlug: "tamranun-ilsang-jeju" },
    { key: "namyangju", itemSlug: "namyangju-trip", placeSlug: "namyangju-water-garden" },
    { key: "flower", title: "성수 도자기 클래스 크래프트 프랙티스", file: "yuna-craft-practice.webp", width: 780, height: 1691, placeSlug: "craft-practice-seongsu" },
  ],
};

const URLS: Record<string, UrlSpec[]> = {
  sena: [
    ["os", "운영체제 페이지 교체 알고리즘 정리", "https://en.wikipedia.org/wiki/Page_replacement_algorithm", "os-assignment"],
    ["library", "중앙도서관 스터디룸 위치", naverMapUrl("서울대학교 중앙도서관"), "library", "central-library-study"],
    ["campus-eats", "샤로수길 덮밥집 후기", naverMapUrl("샤로수길 덮밥"), "sharosu-food", "sharosu-campus-meal"],
    ["team", "팀플 발표 자료 공동 문서", "https://docs.google.com/presentation/", "team-decision"],
    ["dacon", "데이콘 AI 경진대회", "https://dacon.io/", "dacon"],
    ["intern", "여름 개발 인턴 공고 모아보기", "https://www.wanted.co.kr/", "intern"],
    ["mangwon", "망원시장 먹거리 코스", naverMapUrl("망원시장 먹거리"), "mangwon-market", "mangwon-market-food"],
    ["asyncio", "Python asyncio 공식 문서", "https://docs.python.org/3/library/asyncio.html", "python-error"],
    ["dns", "DNS 동작 원리", "https://developer.mozilla.org/ko/docs/Glossary/DNS", "dns"],
    ["agent", "LangChain 에이전트 입문 강의", "https://www.youtube.com/results?search_query=langchain+agent+tutorial", "langchain"],
    ["contest", "교내 창업 공모전 지원 페이지", "https://search.naver.com/search.naver?query=대학생+창업+공모전", "contest"],
    ["loan", "한국장학재단 학자금 안내", "https://www.kosaf.go.kr/", "student-loan"],
    ["concert", "홍대 공연 전 만날 장소", naverMapUrl("KT&G 상상마당 홍대"), "concert", "hongdae-concert"],
    ["mt", "가평역 MT 집결지", naverMapUrl("가평역"), "club-mt", "gapyeong-mt"],
    ["office", "교수님 상담 예약 페이지", "https://calendar.google.com/", "office-hour"],
  ],
  dohyun: [
    ["k8s", "kubectl 공식 치트시트", "https://kubernetes.io/docs/reference/kubectl/quick-reference/", "k8s"],
    ["grafana", "Grafana 대시보드 구성 가이드", "https://grafana.com/docs/grafana/latest/dashboards/", "grafana"],
    ["pangyo-lunch", "판교 점심 회식 후보", naverMapUrl("현대백화점 판교점 맛집"), "pangyo-lunch", "pangyo-team-lunch"],
    ["oom", "Kubernetes OOMKilled 대응법", "https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/", "oom"],
    ["review", "좋은 Pull Request 리뷰 체크리스트", "https://docs.github.com/en/pull-requests", "code-review"],
    ["ddia", "DDIA 실물 확인할 서점", naverMapUrl("교보문고 강남점"), "ddia", "gangnam-tech-books"],
    ["system", "URL 단축기 시스템 디자인", "https://www.youtube.com/results?search_query=url+shortener+system+design", "system-design"],
    ["slack", "Slack API 마이그레이션 문서", "https://api.slack.com/", "slack"],
    ["deploy", "무중단 배포 체크리스트", "https://martinfowler.com/bliki/BlueGreenDeployment.html", "deploy"],
    ["postmortem", "장애 회고 작성 템플릿", "https://sre.google/sre-book/postmortem-culture/", "postmortem"],
    ["gpu", "클라우드 GPU 가격 비교", "https://cloud.google.com/compute/gpus-pricing", "gpu"],
    ["pycon", "PyCon Korea 행사 정보", "https://www.pycon.kr/", "pycon", "coex-pycon"],
    ["dinner", "판교역 팀 회식 집결지", naverMapUrl("판교역"), "team-dinner", "pangyo-team-dinner"],
    ["dentist", "퇴근 후 치과 예약", "https://map.naver.com/p/search/판교%20치과", "dentist", "pangyo-dentist"],
    ["running", "양재시민의숲 러닝 코스", naverMapUrl("양재시민의숲"), "running", "yangjae-run"],
  ],
  yuna: [
    ["bakery", "성수 소금빵 베이커리", "https://search.naver.com/search.naver?query=성수+소금빵", "bakery", "seongsu-bakery"],
    ["recipe", "원팬 토마토 파스타 레시피", "https://www.instagram.com/explore/tags/onepanpasta/", "recipe"],
    ["seoul-forest", "서울숲 카페 약속 장소", naverMapUrl("서울숲"), "cafe-window", "seoul-forest-cafe"],
    ["dress", "리넨 미디 원피스 비교", "https://search.naver.com/search.naver?query=리넨+미디+원피스", "dress"],
    ["mmca", "국립현대미술관 서울 전시", naverMapUrl("국립현대미술관 서울"), "exhibition", "mmca-exhibition"],
    ["salon", "성수 애쉬브라운 잘하는 미용실", "https://map.naver.com/p/search/성수%20미용실", "salon"],
    ["brunch", "연남동 브런치 카페 후보", "https://search.naver.com/search.naver?query=연남동+브런치+카페", "brunch", "yeonnam-brunch"],
    ["popup", "팝업스토어 공간 디자인 레퍼런스", "https://www.pinterest.com/search/pins/?q=popup%20store%20design", "popup"],
    ["yeonnam-pizza", "연남동 화덕피자 후기", "https://www.instagram.com/explore/tags/연남동맛집/", "yeonnam-pizza", "yeonnam-pizza"],
    ["book", "기록에 관한 책과 문장", "https://search.naver.com/search.naver?query=기록의+쓸모+책", "book"],
    ["wedding", "청담 웨딩홀 교통 안내", "https://map.naver.com/p/search/청담%20웨딩홀", "wedding"],
    ["pilates", "출근 전 필라테스 루틴", "https://www.youtube.com/results?search_query=아침+필라테스+루틴", "pilates"],
    ["jeju", "제주 조천 독채 숙소", "https://www.airbnb.co.kr/s/제주-조천읍/homes", "jeju"],
    ["namyangju", "남양주 물의정원", naverMapUrl("물의정원"), "namyangju", "namyangju-water-garden"],
    ["flower", "여름 꽃다발 원데이클래스", "https://search.naver.com/search.naver?query=서울+플라워+원데이클래스", "flower"],
  ],
};

const MEMOS: Record<string, MemoSpec[]> = {
  sena: [
    ["library", "중앙도서관 스터디", "8월 8일 토요일 오전 10시 알고리즘 스터디. 관정관 3층 스터디룸에서 만나기.", "central-library-study"],
    ["mt", "동아리 MT 준비", "8월 22일 오전 10시까지 가평역 1번 출구. 보드게임과 멀티탭 챙기기.", "gapyeong-mt"],
    ["concert", "공연 전 약속", "공연 시작 한 시간 전 KT&G 상상마당 홍대 앞에서 지우 만나기.", "hongdae-concert"],
    ["assignment", "운영체제 과제 체크", "페이지 교체 알고리즘 구현 → 테스트 케이스 5개 → 보고서 PDF → LMS 제출.",],
    ["presentation", "팀플 발표 순서", "데모 영상을 먼저 보여주고 문제 정의, 아키텍처, 성능 비교 순서로 발표하기."],
    ["intern", "인턴 지원 준비", "포트폴리오 프로젝트 설명 3줄로 줄이고, 8월 7일까지 이력서 영문 버전 완성."],
    ["office", "교수님께 여쭤볼 것", "졸업 프로젝트 데이터 수집 범위, IRB 필요 여부, 다음 중간 점검 날짜."],
    ["exam", "네트워크 시험 범위", "DNS, TCP 혼잡제어, HTTP/2. DNS 재귀 질의 그림은 다시 그려보기."],
    ["tuition", "학자금 이자 확인", "자동이체 계좌 잔액 확인하고 8월 19일 전에 이자 납부하기."],
    ["club-dues", "동아리 회비", "이번 학기 회비 3만원. 입금자명 김세나, 총무에게 입금 확인 보내기."],
    ["reading", "이번 달 읽을 개발 글", "RAG 평가, 에이전트 도구 호출, 벡터 검색 실패 사례 글을 하나씩 읽기."],
    ["campus-eats", "샤로수길 혼밥", "공강날 덮밥 먹으러 11시 40분에 출발. 점심 웨이팅은 15분 정도.", "sharosu-campus-meal"],
    ["mangwon", "망원시장 먹거리", "주말에 닭강정부터 사고 고로케와 꽈배기는 포장해서 한강 가기.", "mangwon-market-food"],
    ["gift", "지우 생일 선물", "필름 카메라 스트랩이랑 사진 인화권 중에서 고르기. 예산은 4만원."],
    ["portfolio", "포트폴리오 수정", "프로젝트마다 내가 결정한 것, 실패한 것, 숫자로 달라진 결과를 한 줄씩 추가."],
  ],
  dohyun: [
    ["dinner", "판교역 팀 회식", "8월 28일 금요일 저녁 7시. 판교역 1번 출구에서 모여 양꼬치집으로 이동.", "pangyo-team-dinner"],
    ["bookstore", "DDIA 개정판 확인", "퇴근길 교보문고 강남점에서 파티셔닝 챕터 개정 내용 확인하기.", "gangnam-tech-books"],
    ["running", "주말 러닝", "8월 8일 토요일 아침 양재시민의숲 5km. 매헌역 쪽 입구에서 시작하기.", "yangjae-run"],
    ["deploy", "배포 전 체크", "8월 19일 마이그레이션 dry-run, 대시보드 링크 공유, 롤백 담당자 확인 후 22시 배포."],
    ["incident", "장애 회고 질문", "왜 알림이 늦었나, 메모리 상한은 적절했나, 같은 증상을 자동 탐지할 수 있나."],
    ["review", "코드 리뷰 기준", "멱등성, 타임아웃, 재시도 횟수, 구조화 로그가 빠지지 않았는지 확인."],
    ["side-project", "사이드 프로젝트 아이디어", "러닝 기록을 주간 리포트로 만드는 봇. 스트라바 API와 이메일 요약부터."],
    ["dentist", "치과 스케일링", "8월 24일 월요일 6시 반. 회사에서 20분 걸리니 6시 5분에는 출발.", "pangyo-dentist"],
    ["moving", "이사 준비", "인터넷 이전 신청, 입주 청소 견적 2곳, 전입신고 준비물을 8월 31일까지."],
    ["pt", "PT 재개", "8월 5일 수요일 저녁 8시. 3개월 동안 주 1회는 반드시 지키고 운동 기록 남기기."],
    ["pangyo-lunch", "판교 점심 회식", "현대백화점 판교점 식당가에서 6인 룸 가능한 곳으로 8월 4일까지 예약.", "pangyo-team-lunch"],
    ["subscription", "구독 정리", "안 쓰는 디자인 툴 체험판은 8월 20일 전에 해지하고 클라우드 요금제 비교."],
    ["parents", "부모님 서울 오시는 날", "8월 8일 토요일 점심 예약하고 주차 편한 식당 두 곳만 추려서 보내드리기."],
    ["tax", "연말정산 메모", "안경 구입 영수증과 월세 이체 내역은 별도 폴더에 모아두기."],
    ["pycon", "PyCon 가는 날", "8월 15일 코엑스 그랜드볼룸 입구에서 오전 9시에 스터디원 만나기. 명함과 충전기 챙기기.", "coex-pycon"],
  ],
  yuna: [
    ["seoul-forest", "서울숲 카페 약속", "8월 8일 토요일 오후 2시 서울숲 입구에서 만나 통창 카페 가기.", "seoul-forest-cafe"],
    ["mmca", "국립현대미술관 전시", "8월 9일 일요일 오후 서울관 전시 보고 삼청동 카페까지 걸어가기.", "mmca-exhibition"],
    ["namyangju", "남양주 당일치기", "8월 29일 물의정원은 오전에 먼저 들르고 점심 뒤 카페거리로 이동하기.", "namyangju-water-garden"],
    ["gift", "엄마 생신 선물", "실크 스카프, 홍삼 스틱, 애프터눈티 중에서 고르고 8월 14일까지 주문."],
    ["salon", "미용실 요청", "8월 23일 애쉬브라운으로 톤 다운. 얼굴 옆 레이어드는 유지하고 앞머리는 자르지 않기."],
    ["pilates", "필라테스 시간 변경", "8월부터 화·목 저녁 7시 대신 아침 7시 반. 전날 운동복 챙기기."],
    ["yeonnam-pizza", "연남동 화덕피자", "인스타에서 본 라구 피자 먹기. 경의선숲길 산책 전 테라스 자리 확인.", "yeonnam-pizza"],
    ["groceries", "주말 장보기", "방울토마토, 바질, 모차렐라, 탄산수. 파스타면과 올리브오일은 있음."],
    ["cafe", "성수 소금빵", "품절 전에 11시쯤 들르고 서울숲으로 이동. 비 오면 포장만 하기.", "seongsu-bakery"],
    ["dress", "원피스 사이즈 메모", "크림은 S, 세이지는 M 핏이 예쁨. 총장 118cm 이상이면 수선 필요."],
    ["brunch", "연남동 브런치", "일요일 늦은 아침 테라스 자리 확인하고 경의선숲길 산책 전에 들르기.", "yeonnam-brunch"],
    ["wedding", "수민이 결혼식", "축의금 봉투 미리 준비하고 11시 40분까지 도착. 식 끝나고 대학 친구들과 사진."],
    ["movies", "이번 달 볼 영화", "이터널 선샤인 재개봉, 바다의 기억 다큐, 주말에 볼 짧은 애니 하나."],
    ["budget", "월급 배분 규칙", "저축 40, 생활 40, 즐거움 20. 즐거움 계좌가 비면 그 달 소비는 끝."],
    ["flowers", "꽃 오래 보는 법", "물은 이틀에 한 번 갈고 줄기 끝 1cm 사선으로 자르기. 직사광선 피하기."],
  ],
};

/** 현재 페르소나에 맞춘 고유한 기록 예시 15건씩을 만든다. */
export function captureExamplesFor(persona: SeedPersona): CaptureExample[] {
  const itemBySlug = new Map(persona.items.map((item) => [item.slug, item]));
  const placeBySlug = new Map((PLACE_EXAMPLES[persona.slug] ?? []).map((place) => [place.slug, place]));

  const screenshots = (SCREENSHOTS[persona.slug] ?? []).flatMap((spec): ScreenshotExample[] => {
    const item = "itemSlug" in spec ? itemBySlug.get(spec.itemSlug) : undefined;
    const image = item?.image ?? ("file" in spec
      ? {
          file: `/seed/examples/${spec.file}`,
          width: spec.width ?? 780,
          height: spec.height ?? 1688,
        }
      : undefined);
    if (!image) return [];
    return [{
      id: `${persona.slug}-shot-${spec.key}`,
      kind: "screenshot",
      title: "title" in spec ? spec.title : item!.title,
      image,
      place: spec.placeSlug ? placeBySlug.get(spec.placeSlug)?.place : undefined,
    }];
  });
  const urls = (URLS[persona.slug] ?? []).map(([key, title, url, , placeSlug]): CaptureExample => {
    return {
      id: `${persona.slug}-url-${key}`,
      kind: "url",
      title,
      url,
      image: {
        file: `/seed/examples/links/${persona.slug}-${key}-v2.png`,
        width: 1280,
        height: 720,
      },
      place: placeSlug ? placeBySlug.get(placeSlug)?.place : undefined,
    };
  });

  const memos = (MEMOS[persona.slug] ?? []).map(([key, title, text, placeSlug]): CaptureExample => ({
    id: `${persona.slug}-memo-${key}`,
    kind: "memo",
    title,
    text,
    place: placeSlug ? placeBySlug.get(placeSlug)?.place : undefined,
  }));

  return [...screenshots, ...urls, ...memos];
}
