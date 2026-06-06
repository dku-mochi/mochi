# GCS image inventory

- model: `gemini-3.1-flash-lite`
- images analyzed: 30
- usable for lab eval (suitability >= 3 and not high sensitivity): 17
- mean suitability: 2.93

## Distribution

- by category: `{"calendar_or_event": 2, "chat_or_social": 5, "media": 11, "product": 7, "unknown": 5}`
- by sensitivity: `{"low": 26, "medium": 4}`
- by stressor: `{"ambiguous_user_intent": 4, "date_not_schedule": 1, "deadline": 4, "low_context": 15, "multi_instance": 3, "payload_extraction": 11, "review_options": 7}`

## Best candidates

- `584789139516a3bef6ac40c83fbc4eb137558b8874e7ba2b8d6cfcfa6ddbac22.jpg` score=5 sensitivity=low category=chat_or_social intents=['memo'] review=True stressors=['ambiguous_user_intent', 'review_options'] — 모찌 앱의 홈 화면으로, 사용자가 공유한 유튜브 링크에 대해 모찌가 의도를 파악하지 못해 사용자에게 확인을 요청하는 상태입니다.
- `6abe686ecc8859908c00b730fb70b0152d54250014b622127476a8540b50bddf.jpg` score=5 sensitivity=low category=calendar_or_event intents=['todo'] review=False stressors=['deadline', 'payload_extraction'] — 모찌 앱의 홈 화면으로, '교육 수강'이라는 할 일 항목이 마감일(12월 31일 오후 11시 59분)과 함께 표시되어 있습니다.
- `bc47e62e2ee01fe44f20fab63f0a0e6d9871acc4649e6c737051d43167a1db16.jpg` score=5 sensitivity=low category=calendar_or_event intents=['schedule', 'todo'] review=True stressors=['deadline', 'payload_extraction'] — 2026년 AI·가상융합(XR) 서비스 개발자 경진대회 참가 신청 안내 이미지입니다. 신청 기간은 5월 13일부터 6월 26일까지입니다.
- `c054ed9fd6325a08773ba7049167212436e0bb5e052e33d272e003d075f6e11a.jpg` score=5 sensitivity=low category=chat_or_social intents=['memo', 'todo'] review=True stressors=['ambiguous_user_intent', 'review_options', 'multi_instance'] — 모찌 앱의 홈 화면으로, 사용자가 저장한 유튜브 링크에 대한 의도를 파악하지 못해 사용자에게 확인을 요청하는 상태이며, 하단에는 '할일'로 분류된 바디워시 관련 스크린샷들이 나열되어 있습니다.
- `c84b1fddf5d2db73ea87092afe4c75d484235d154cdf3246902a425fc80203b7.jpg` score=5 sensitivity=low category=unknown intents=['memo'] review=True stressors=['ambiguous_user_intent', 'review_options'] — 모찌 앱의 분석 대기 화면으로, 사용자가 의도를 선택해야 하는 상황입니다.
- `bbb228d4affae92500dc8e5b5e992f757bc7597bd2372d08140f7210d3028b76.jpg` score=5 sensitivity=medium category=chat_or_social intents=['schedule', 'todo'] review=True stressors=['payload_extraction', 'deadline', 'review_options'] — 서울도시가스 안전점검 안내 메시지 및 방문 일정 조율 대화
- `528fdd69dad1f1514038e19e9328b9433b9b60615d79feb1b77165445ec3b9c2.jpg` score=4 sensitivity=low category=product intents=['todo'] review=False stressors=['multi_instance'] — 모찌 앱의 홈 화면으로, 사용자가 저장한 스크린샷 기반의 할 일 목록과 '중요해 보여요' 섹션이 표시되어 있습니다.
- `57b8cb156eb53544df69abbcb61bf9577e7d974969a7da4f7a836163a6b570d8.jpg` score=4 sensitivity=low category=media intents=['schedule'] review=True stressors=['payload_extraction', 'review_options'] — 인스타그램에서 소고기 된장찌개 음식 사진과 함께 '지금 예약하기' 버튼이 포함된 게시물
- `5e85e08e1c83effa636fe98c87ba5ed1796e542bc5eff0b1962c3c96df27e14d.jpg` score=4 sensitivity=low category=product intents=['schedule'] review=True stressors=['payload_extraction', 'review_options'] — 인스타그램 광고로 노출된 '지팡갈비' 식당 홍보 게시물이며, '지금 예약하기' 버튼이 포함되어 있습니다.
- `8d45a4425fa5bce3b4ed6367ea6bf42b26c958e20c47dfd9df96d01aa93164cf.jpg` score=4 sensitivity=low category=product intents=['schedule'] review=True stressors=['date_not_schedule', 'payload_extraction'] — 알리익스프레스 썸머 세일 광고 이미지로, 6월 1일부터 6월 10일까지 진행되는 할인 행사 정보를 담고 있습니다.
- `97e43eed6fda415c19edb7d8b5f6da4c4d7e3b0c989e303002241a91a9fcffca.png` score=4 sensitivity=low category=product intents=['todo'] review=True stressors=['deadline', 'payload_extraction', 'review_options'] — 로지텍 MX 마스터 3S 무선 마우스 상품 상세 페이지로, 타임 할인 정보와 도착 예정일이 표시되어 있습니다.
- `3f96fb59258b0944d03831b2d4dd2b37a08d486c715bc2795fecde42a1bc977e.jpg` score=4 sensitivity=medium category=chat_or_social intents=['knowledge'] review=False stressors=['multi_instance', 'payload_extraction'] — 텔레그램 봇(junseocccbot-1)으로부터 수신된 주식 시장 및 포트폴리오 변동 알림 메시지들입니다.
- `5ff895b9a1314588e88f65012f74c8d374542c6d61be6280285cd2e8a1d9fcd1.jpg` score=4 sensitivity=medium category=product intents=['schedule'] review=True stressors=['ambiguous_user_intent', 'payload_extraction'] — 카카오톡 선물하기 화면으로, 오늘 생일인 친구(최재민)와 지난 생일인 가족(아빠) 정보가 표시되어 있습니다.
- `0082d3fbf37c2d1f89a8afacb0aa41377f01b05d2e39ab2794b35a0f4db472f5.jpg` score=3 sensitivity=low category=product intents=['memo'] review=False stressors=['payload_extraction'] — 모찌 앱의 홈 화면으로, 사용자가 저장한 '아르베 비터버터 바디워시' 관련 스크린샷이 '중요해 보여요' 및 '최근 추가한 모찌' 섹션에 표시되어 있습니다.
- `105931b75a71b3c71a190b60669f8d9d6e175b24fdf99860db1ee1268c556bec.jpg` score=3 sensitivity=low category=media intents=['knowledge'] review=False stressors=['low_context'] — 다니엘 시저 콘서트 하이라이트 영상 게시물
- `e75ac75dfed21ce6becdbfad172b9a502b35b752410517bdcb79b6613c678e0a.jpg` score=3 sensitivity=low category=media intents=['knowledge'] review=False stressors=['low_context'] — Claude의 새로운 다이내믹 워크플로우 기능에 대한 유튜브 영상 화면입니다.
- `ea740f9a6da381a30811744e1894b17131a463cfc6f0eee40e835cef15c7d629.jpg` score=3 sensitivity=low category=media intents=['memo'] review=False stressors=['payload_extraction'] — 참치회 먹방 쇼츠 영상으로, 화면 상단에 '미니 도시락김' 제품 정보가 노출되어 있습니다.

## Exclusions / caution

- `01155271f39cfa3a6730b07585cf39c3db724e2a07bb6337ceda7f841484b967.jpg` score=2 sensitivity=low — 사용자의 명확한 의도나 저장할 만한 구체적인 정보가 부족한 일반적인 피드 화면입니다.
- `0b1c948f6d9eee927144a65038e12454078d3be655992eefe2bf29fd97022469.jpg` score=2 sensitivity=low — 사용자가 수행할 명확한 의도(일정, 할 일, 메모 등)가 부족하며, 단순 정보성 콘텐츠입니다.
- `15cf7b4cb569cd7f7632dabe7d541fc46a7a2837059988a6227a7f309e851691.jpg` score=1 sensitivity=low — 사용자 의도나 데이터 추출이 가능한 정보가 전혀 없는 시스템 화면이므로 학습에 부적합합니다.
- `16404a02c1604ffb0e3e9e92acc8065a1a55dfcd2d4aee6806dd51cc14721581.jpg` score=1 sensitivity=medium — 특정 인텐트(일정, 할 일, 메모 등)를 추출할 수 있는 정보가 없는 일반적인 홈 화면 스크린샷입니다.
- `1bc23d2c674863cce312a923bb984e3d4a2772f50bcf5c8a4c99766691ddf599.jpg` score=1 sensitivity=low — 사용자의 의도(일정, 할 일, 메모 등)가 전혀 포함되지 않은 단순 이미지 콘텐츠이므로 데이터셋으로 부적합합니다.
- `1c1bc10b0771477ee4472f81eeb1c99b52cecb504b6810aa7e78fdd34f8e2ea7.jpg` score=1 sensitivity=low — 특정 의도(intent)를 추출할 수 있는 작업 화면이 아니며, 단순히 앱 아이콘들이 나열된 홈 화면입니다.
- `1c8f0d28362cc96b58f814cd3899de964c9d3f39563fdd563644dd257004b41b.jpg` score=2 sensitivity=low — 사용자의 명확한 의도(일정, 할 일, 메모 등)가 포함되어 있지 않고, 단순히 유튜브 시청 중인 화면이라 데이터로서의 가치가 낮습니다.
- `650cd8aca1b4fcf3b63373211e80421138553c41ccb7dbc80777a7e307bf0027.jpg` score=1 sensitivity=low — 사용자의 의도(일정, 메모, 지식 검색 등)를 추출할 만한 요소가 전혀 없는 단순 미디어 소비 화면입니다.
- `7b20888d2949e8977c9b37cdb8a648f540e5ab51c8504d252148d14aecfc98b8.jpg` score=1 sensitivity=low — 사용자의 개인적인 일정, 할 일, 메모 등 MOCHI 스키마에 적합한 의도가 전혀 포함되어 있지 않은 일반적인 미디어 소비 화면입니다.
- `940a9534812ce96127bcb4bdf0560a00f2be7afa4ce3a7ca60a60a3652cdc325.jpg` score=1 sensitivity=low — 사용자의 능동적인 의도(일정, 메모, 할 일 등)가 전혀 포함되지 않은 단순 미디어 시청 화면입니다.
- `d156227e5f95eff74cdf591b0d05d9596acd11bfe627f833ee9bd59621d9b581.jpg` score=1 sensitivity=low — 사용자의 의도(intent)를 추출할 수 있는 정보가 부족하며, 일반적인 스크린샷이 아닌 일상적인 사진임
- `d833f08fa5b0cea415d60bf43aee192d0f7e95ce1b8c9883133fe03521b1ee2b.jpg` score=2 sensitivity=low — 사용자가 수행할 수 있는 명확한 작업(일정, 할 일, 메모 등)이 없으며, 단순 미디어 소비 화면이라 데이터 추출 가치가 낮습니다.
- `fb4785e8e3617398af404d60b106ccadef1d7acdde821e058b0c4718e6787707.jpg` score=2 sensitivity=low — 단순 광고 이미지로, 사용자가 직접적인 의도를 가지고 생성한 데이터가 아니며 추출할 만한 구조화된 정보(날짜, 시간, 할 일 등)가 부족합니다.