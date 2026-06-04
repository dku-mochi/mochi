# Validation image-only eval

- model: `gemini-3.1-flash-lite`
- input policy: image only; no filename; no user memo
- items: 15
- mean intent F1: 0.9111
- count accuracy: 0.9333
- review accuracy: 1
- review_options shape accuracy: 1

## Failures / Drift

- `validation_10_스케줄.jpg` gold=['schedule'] pred=['schedule', 'knowledge'] review=False f1=0.6667 count=False — 삼성디스플레이 아름타운 기숙사 생활 안내 및 비데 정기점검 일정
- `validation_13_나중에 살 화장품.jpg` gold=['todo'] pred=['knowledge'] review=False f1=0.0 count=True — 바닐라 향 제품 추천 및 관련 정보 저장

## Per Case

- `validation_01_친구 공연 위치랑 장소 캡쳐.jpg`: gold=['schedule'], pred=['schedule'], review=False, options=0, summary=너와나 2024년 겨울 정기공연 안내
- `validation_02_수강 모집 9:8까지니까 캡쳐해두고 나중에신청해야지.jpg`: gold=['schedule', 'todo'], pred=['schedule', 'todo'], review=False, options=0, summary=고려대학교 지속가능원 주관 '해양환경 시민 과학자 양성 과정' 수강생 모집 안내
- `validation_03_공차 할인 이벤트하니까 캡쳐해두고 나중에 가봐야지.jpg`: gold=['schedule', 'todo'], pred=['schedule', 'todo'], review=False, options=0, summary=공차 900호점 기념 해피아워 이벤트 정보입니다.
- `validation_04_제출 기간 체크.jpg`: gold=['schedule', 'todo'], pred=['schedule', 'todo'], review=False, options=0, summary=PT 발표 자료 제출 기한 안내
- `validation_05_기프티콘 나중에 꼭 써야지.jpg`: gold=['todo'], pred=['todo'], review=False, options=0, summary=메가MGC커피 5,000원 모바일 금액권 저장
- `validation_06_상하이 정보.jpg`: gold=['knowledge'], pred=['knowledge'], review=False, options=0, summary=상하이 푸동공항에서 시내로 이동하는 마그레브 열차 이용 정보
- `validation_07_상하이 여행정보.jpg`: gold=['knowledge'], pred=['knowledge'], review=False, options=0, summary=상하이 여행지 추천 정보가 담긴 숏폼 영상 캡처
- `validation_08_중국 여행 정보.jpg`: gold=['knowledge'], pred=['knowledge'], review=False, options=0, summary=중국 여행 시 필요한 필수 앱 목록 정보
- `validation_09_비행기 스케줄.jpg`: gold=['schedule'], pred=['schedule'], review=False, options=0, summary=서울-상하이 왕복 항공권 예약 정보
- `validation_10_스케줄.jpg`: gold=['schedule'], pred=['schedule', 'knowledge'], review=False, options=0, summary=삼성디스플레이 아름타운 기숙사 생활 안내 및 비데 정기점검 일정
- `validation_11_부동산 정보.jpg`: gold=['knowledge'], pred=['knowledge'], review=False, options=0, summary=인스타그램 DM을 통해 받은 신림동 다올626 매물 정보입니다.
- `validation_12_재밌어 보이는 넷플.jpg`: gold=['memo'], pred=['memo'], review=False, options=0, summary=스레드에서 추천받은 넷플릭스 다큐멘터리 '서바잉 데스'와 이케가와 아키라 저서에 대한 기록입니다.
- `validation_13_나중에 살 화장품.jpg`: gold=['todo'], pred=['knowledge'], review=False, options=0, summary=바닐라 향 제품 추천 및 관련 정보 저장
- `validation_14_나중에 살 신발.jpg`: gold=['todo'], pred=['todo'], review=False, options=0, summary=로제니크 세릭 스틸레토 스트랩 슬링백힐 상품 정보 저장
- `validation_15_화장품 나중에 살것.jpg`: gold=['todo'], pred=['todo'], review=False, options=0, summary=디어달리아 립 제품 정보 및 구매 고려