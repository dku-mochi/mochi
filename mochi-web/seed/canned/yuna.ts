import type { SeedCannedChat, SeedCannedSearch } from "../schema";

export const yunaChat: SeedCannedChat[] = [
  {
    id: "yuna-dress",
    triggers: ["원피스", "옷", "드레스", "쇼핑", "캡처한"],
    script: [
      { type: "tool_started", name: "search_items", label: "기록을 뒤지고 있어요…" },
      { type: "tool_finished", name: "search_items", summary: "쇼핑 캡처 1건" },
      {
        type: "message_delta",
        text: "6일 전에 캡처해두신 **린넨 라이크 미디 원피스**[1]예요.\n\n- 크림·세이지 2색, 89,000원\n- 여름 프리오더 **10% 쿠폰이 7/10까지** - 이제 3일 남았어요\n\n이번 주에만 두 번 다시 보셨더라고요. 결정할 때가 된 것 같아요.",
      },
      { type: "citation", index: 1, itemSlug: "shop-linen-dress" },
      {
        type: "proposal",
        proposalType: "reminder",
        payload: { title: "원피스 쿠폰 마감", note: "7/10 오전 알림", time: "7/10 10:00" },
      },
    ],
  },
  {
    id: "yuna-weekend",
    triggers: ["주말", "추천", "갈 만한", "어디", "카페"],
    script: [
      { type: "tool_started", name: "search_items", label: "저장해둔 장소를 모으고 있어요…" },
      {
        type: "tool_finished",
        name: "search_items",
        summary: "성수 카페 3곳 + 전시 1건",
      },
      {
        type: "message_delta",
        text: "이번 주말이면 성수 코스가 딱이에요.\n\n- 오전: **소금빵 베이커리**[1] - 11시 전 도착 추천\n- 낮: **빛의 정원 미디어아트**[4] - 금요일 14시에 2차 예매가 열려요\n- 오후: **통창 서울숲 뷰 카페**[2] - 주말이라 웨이팅은 있어요\n\n브런치 카페[3]는 웨이팅 30분이라 다음 평일에 아껴두는 게 나아요.",
      },
      { type: "citation", index: 1, itemSlug: "insta-cafe-bakery" },
      { type: "citation", index: 2, itemSlug: "insta-cafe-window" },
      { type: "citation", index: 3, itemSlug: "insta-cafe-brunch" },
      { type: "citation", index: 4, itemSlug: "exhibition-booking" },
      {
        type: "proposal",
        proposalType: "create_schedule",
        payload: { title: "성수 카페 코스", date: "토요일", time: "10:30" },
      },
    ],
  },
];

export const yunaSearch: SeedCannedSearch[] = [
  {
    id: "yuna-search-dress",
    triggers: ["원피스", "옷", "쇼핑"],
    citationSlugs: ["shop-linen-dress"],
  },
  {
    id: "yuna-search-cafe",
    triggers: ["성수", "카페", "빵"],
    citationSlugs: ["insta-cafe-bakery", "insta-cafe-window", "insta-cafe-brunch"],
  },
  {
    id: "yuna-search-gift",
    triggers: ["선물", "엄마", "생신", "생일"],
    citationSlugs: ["gift-mom"],
  },
];
