# Validation user memo eval

- model: `gemini-3.1-flash-lite`
- items: 15

## Results

- `친구 공연 위치랑 장소 캡쳐`: intents=['schedule'], review=False, options=0, summary=친구 공연 일정 및 장소 정보 저장
- `수강 모집 9:8까지니까 캡쳐해두고 나중에신청해야지`: intents=['todo', 'schedule'], review=False, options=0, summary=고려대학교 Sustainable Development Goals Academy 수강 신청을 위한 정보 저장
- `공차 할인 이벤트하니까 캡쳐해두고 나중에 가봐야지`: intents=['schedule', 'todo'], review=False, options=0, summary=공차 900호점 기념 해피아워 이벤트 정보 저장
- `제출 기간 체크`: intents=['schedule', 'todo'], review=False, options=0, summary=PT 발표 자료 제출 기한 확인
- `기프티콘 나중에 꼭 써야지`: intents=['todo'], review=False, options=0, summary=메가MGC커피 5천원권 기프티콘 사용을 위한 할 일 등록
- `상하이 정보`: intents=['knowledge'], review=False, options=0, summary=상하이 푸동공항에서 시내로 이동하는 마그레브 열차 이용 정보
- `상하이 여행정보`: intents=['knowledge'], review=False, options=0, summary=상하이 여행 정보가 담긴 영상 캡처입니다.
- `중국 여행 정보`: intents=['knowledge'], review=False, options=0, summary=중국 여행 시 필요한 필수 앱 목록 정보
- `비행기 스케줄`: intents=['schedule'], review=False, options=0, summary=서울-상하이 왕복 항공권 예약 정보입니다.
- `스케줄`: intents=['schedule'], review=False, options=0, summary=삼성디스플레이 기숙사 비데 정기점검 일정
- `부동산 정보`: intents=['knowledge'], review=False, options=0, summary=부동산 매물 정보 저장
- `재밌어 보이는 넷플`: intents=['memo'], review=False, options=0, summary=스레드에서 추천받은 넷플릭스 다큐멘터리 '서바이빙 데스'에 대한 메모입니다.
- `나중에 살 화장품`: intents=['todo'], review=False, options=0, summary=나중에 살 화장품으로 Bath and Body Works의 바닐라 향 제품 추천 정보를 저장합니다.
- `나중에 살 신발`: intents=['todo'], review=False, options=0, summary=사용자가 나중에 구매하기 위해 저장한 신발 정보입니다.
- `화장품 나중에 살것`: intents=['todo'], review=False, options=0, summary=디어달리아 립 제품 구매를 위한 저장