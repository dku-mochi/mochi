# Image intent_instances + review_options eval

- model: `gemini-3.1-flash-lite`
- images: 26
- mean intent F1: 0.9103
- count accuracy: 0.9615
- review accuracy: 1
- review_options shape accuracy: 1
- payload quality: 1.0

## Failures / Drift

- `01155271f39cfa3a6730b07585cf39c3db724e2a07bb6337ceda7f841484b967.jpg` gold=['knowledge']/False pred=['memo']/False f1=0.0 count=True review=True options_shape=True — 인스타그램 피드에 노출된 조화 인테리어 관련 게시물과 사주/운세 서비스 광고입니다.
- `8d45a4425fa5bce3b4ed6367ea6bf42b26c958e20c47dfd9df96d01aa93164cf.jpg` gold=['knowledge']/False pred=['memo']/False f1=0.0 count=True review=True options_shape=True — 알리익스프레스 썸머 세일 광고
- `bbb228d4affae92500dc8e5b5e992f757bc7597bd2372d08140f7210d3028b76.jpg` gold=['schedule', 'todo']/False pred=['todo']/False f1=0.6667 count=False review=True options_shape=True — 서울도시가스 안전점검 방문 예약 관련 문자 메시지

## Per Case

- `01155271f39cfa3a6730b07585cf39c3db724e2a07bb6337ceda7f841484b967.jpg`: pred=['memo'], review=False, options=0, summary=인스타그램 피드에 노출된 조화 인테리어 관련 게시물과 사주/운세 서비스 광고입니다.
- `0b1c948f6d9eee927144a65038e12454078d3be655992eefe2bf29fd97022469.jpg`: pred=['memo'], review=False, options=0, summary=eyesmag 인스타그램의 '백룸' 관련 게시물입니다.
- `105931b75a71b3c71a190b60669f8d9d6e175b24fdf99860db1ee1268c556bec.jpg`: pred=['memo'], review=False, options=0, summary=다니엘 시저 콘서트 하이라이트 영상 게시물
- `1bc23d2c674863cce312a923bb984e3d4a2772f50bcf5c8a4c99766691ddf599.jpg`: pred=['memo'], review=False, options=0, summary=로보캅 관련 만화 컷을 담은 인스타그램 게시물
- `1c8f0d28362cc96b58f814cd3899de964c9d3f39563fdd563644dd257004b41b.jpg`: pred=['knowledge'], review=False, options=0, summary=수학적 직관 및 개발 관련 지식 콘텐츠를 담은 유튜브 영상 화면입니다.
- `3f96fb59258b0944d03831b2d4dd2b37a08d486c715bc2795fecde42a1bc977e.jpg`: pred=['knowledge'], review=False, options=0, summary=주식 포트폴리오 변동 및 시장 상황 알림 메시지
- `57b8cb156eb53544df69abbcb61bf9577e7d974969a7da4f7a836163a6b570d8.jpg`: pred=['memo'], review=False, options=0, summary=소고기 된장찌개 맛집 게시물
- `584789139516a3bef6ac40c83fbc4eb137558b8874e7ba2b8d6cfcfa6ddbac22.jpg`: pred=['memo'], review=True, options=2, summary=모찌 앱의 홈 화면으로, 사용자가 저장한 유튜브 링크에 대해 분류가 필요하여 '모찌가 헷갈려요' 섹션에 표시된 상태입니다.
- `5e85e08e1c83effa636fe98c87ba5ed1796e542bc5eff0b1962c3c96df27e14d.jpg`: pred=['memo'], review=False, options=0, summary=마늘 듬뿍 지팡갈비 맛집 광고 게시물
- `5ff895b9a1314588e88f65012f74c8d374542c6d61be6280285cd2e8a1d9fcd1.jpg`: pred=['todo'], review=False, options=0, summary=카카오톡 선물하기 화면에서 오늘 생일인 최재민 님에게 선물을 보내야 함을 확인했습니다.
- `650cd8aca1b4fcf3b63373211e80421138553c41ccb7dbc80777a7e307bf0027.jpg`: pred=['memo'], review=False, options=0, summary=SNL 코리아 리부트 시즌 7의 유머 영상 캡처입니다.
- `7b20888d2949e8977c9b37cdb8a648f540e5ab51c8504d252148d14aecfc98b8.jpg`: pred=['memo'], review=False, options=0, summary=유튜브 영상 시청 및 다나성형외과 광고 확인
- `8d45a4425fa5bce3b4ed6367ea6bf42b26c958e20c47dfd9df96d01aa93164cf.jpg`: pred=['memo'], review=False, options=0, summary=알리익스프레스 썸머 세일 광고
- `940a9534812ce96127bcb4bdf0560a00f2be7afa4ce3a7ca60a60a3652cdc325.jpg`: pred=['knowledge'], review=False, options=0, summary=CodeFactory 채널의 Opus 4.8 관련 기술 영상과 FC 온라인 광고가 포함된 유튜브 화면입니다.
- `97e43eed6fda415c19edb7d8b5f6da4c4d7e3b0c989e303002241a91a9fcffca.png`: pred=['memo'], review=False, options=0, summary=로지텍 MX 마스터 3S 무선 마우스 상품 정보
- `bbb228d4affae92500dc8e5b5e992f757bc7597bd2372d08140f7210d3028b76.jpg`: pred=['todo'], review=False, options=0, summary=서울도시가스 안전점검 방문 예약 관련 문자 메시지
- `bc47e62e2ee01fe44f20fab63f0a0e6d9871acc4649e6c737051d43167a1db16.jpg`: pred=['schedule', 'todo'], review=False, options=0, summary=2026년 AI·가상융합(XR) 서비스 개발자 경진대회 참가 신청 안내
- `d156227e5f95eff74cdf591b0d05d9596acd11bfe627f833ee9bd59621d9b581.jpg`: pred=['memo'], review=False, options=0, summary=대여용 양말에 적힌 '사용 후 돌려주세요' 문구 사진
- `d833f08fa5b0cea415d60bf43aee192d0f7e95ce1b8c9883133fe03521b1ee2b.jpg`: pred=['memo'], review=False, options=0, summary=인스타그램 릴스에 올라온 한로로의 '입춘' 노래 영상입니다.
- `e75ac75dfed21ce6becdbfad172b9a502b35b752410517bdcb79b6613c678e0a.jpg`: pred=['knowledge'], review=False, options=0, summary=Claude의 새로운 Dynamic Workflows 기능에 대한 기술 정보가 담긴 유튜브 영상입니다.
- `ea740f9a6da381a30811744e1894b17131a463cfc6f0eee40e835cef15c7d629.jpg`: pred=['memo'], review=False, options=0, summary=참치회 먹는 영상과 함께 미니 도시락김 제품이 노출된 유튜브 쇼츠 화면입니다.
- `fb4785e8e3617398af404d60b106ccadef1d7acdde821e058b0c4718e6787707.jpg`: pred=['memo'], review=False, options=0, summary=인스타그램 광고로 노출된 아르베(arwe) 바디워시 제품 정보입니다.
- `img_8541_resized.jpg`: pred=['knowledge'], review=False, options=0, summary=레이밴 메타 헤드라이너 스마트 글래스 제품 정보
- `img_8542_resized.jpg`: pred=['knowledge'], review=False, options=0, summary=선관위의 투표용지 부족 사태에 대한 뉴스 게시물입니다.
- `img_8543_resized.jpg`: pred=['knowledge'], review=False, options=0, summary=유튜버 퓨디파이가 공개한 로컬 AI 워크스페이스 '오디세우스'에 대한 정보
- `img_8544_resized.jpg`: pred=['knowledge', 'todo'], review=False, options=0, summary=AI를 활용해 HWPX 파일을 쉽게 편집하는 클로드 스킬 및 가이드 제공 게시물