# user_memo regression — image-only V14 vs V15

- model: `gemini-3.1-flash-lite` / location: `global` / temperature 0.3 / thinking_budget 0
- input policy: image only; no user_memo / no url / no filename / no recent context
- images: 34
- errors: V14=0 [] / V15=0 []

## Intent hit (pred intent_types ∩ gold_intents ≠ ∅)

- V14: 26/34 = 0.7647
- V15: 25/34 = 0.7353

## intent_types diff (V14 ↔ V15): 1 images

- `memo_중국갈때설치할거.jpeg` gold=['memo']: V14=['memo'] → V15=['todo']

## Per case

- `knowledge_시험공부할때보려고.jpg` gold=['knowledge'] | V14 intents=['knowledge'] review=False cat=딥러닝 학습 | V15 intents=['knowledge'] review=False cat=딥러닝 학습
- `memo_knowledge_식단짤때참고하려고.png` gold=['memo', 'knowledge'] | V14 intents=['memo'] review=False cat=식단 관리 | V15 intents=['memo'] review=False cat=식단 관리
- `memo_todo_저날이후로보러가려고 (2).png` gold=['memo', 'todo'] | V14 intents=['memo'] review=False cat=영화 관람 | V15 intents=['memo'] review=False cat=영화 관람
- `memo_todo_저날이후로보러가려고.png` gold=['memo', 'todo'] | V14 intents=['memo'] review=True cat=영화 관람 | V15 intents=['memo'] review=True cat=영화 관람
- `memo_todo_해당날짜전까지등록하려고.png` gold=['memo', 'todo'] | V14 intents=['todo'] review=False cat=교통비 환급 | V15 intents=['todo'] review=False cat=교통비 환급
- `memo_기프티콘나중에꼭써야지.jpeg` gold=['memo'] | V14 intents=['memo'] review=False cat=쿠폰/기프티콘 | V15 intents=['memo'] review=False cat=쿠폰 관리
- `memo_나중에가보려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=카페 탐방 | V15 intents=['memo'] review=False cat=카페 탐방
- `memo_나중에가보려고저장.png` gold=['memo'] | V14 intents=['memo'] review=False cat=데이트 코스 | V15 intents=['memo'] review=False cat=데이트 코스
- `memo_나중에먹어보려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=맛집 탐방 | V15 intents=['memo'] review=False cat=맛집 탐방
- `memo_나중에사먹으려고.jpg` gold=['memo'] | V14 intents=['memo'] review=False cat=건강 관리 | V15 intents=['memo'] review=False cat=건강 관리
- `memo_나중에살신발.png` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=쇼핑 후보
- `memo_나중에살화장품.png` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=쇼핑 후보
- `memo_나중에써봐야지.PNG` gold=['memo'] | V14 intents=['knowledge'] review=False cat=AI 도구 정보 | V15 intents=['knowledge'] review=False cat=AI 도구 정보
- `memo_나중에여행갈때참고하려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=여행 정보 | V15 intents=['memo'] review=False cat=여행 정보
- `memo_넷플릭스에서볼것들.png` gold=['memo'] | V14 intents=['memo', 'memo'] review=False cat=독서 및 콘텐츠 추천 | V15 intents=['memo'] review=False cat=콘텐츠 추천
- `memo_다음운동때참고하려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=운동 기록 | V15 intents=['memo'] review=False cat=운동 기록
- `memo_머리자를때참고하려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=헤어 스타일 | V15 intents=['memo'] review=False cat=헤어 스타일
- `memo_부동산정보.png` gold=['memo'] | V14 intents=['memo'] review=True cat=부동산 매물 | V15 intents=['memo'] review=False cat=부동산 매물
- `memo_사고싶다.PNG` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=쇼핑 후보
- `memo_상하이갈곳들.jpeg` gold=['memo'] | V14 intents=['memo'] review=False cat=여행 계획 | V15 intents=['memo'] review=False cat=여행 후보
- `memo_상하이정보.jpeg` gold=['memo'] | V14 intents=['memo'] review=False cat=여행 정보 | V15 intents=['memo'] review=False cat=여행 정보
- `memo_옷살때참고하려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=패션 정보
- `memo_이뻐서나중에가보려고.png` gold=['memo'] | V14 intents=['memo'] review=False cat=데이트 코스 | V15 intents=['memo'] review=False cat=나들이 후보
- `memo_저장해두고나중에봐야지.PNG` gold=['memo'] | V14 intents=['memo'] review=False cat=업무 생산성 | V15 intents=['memo'] review=False cat=업무 생산성
- `memo_중국갈때설치할거.jpeg` gold=['memo'] | V14 intents=['memo'] review=False cat=중국 여행 준비 | V15 intents=['todo'] review=False cat=중국 여행 준비
- `memo_화장품나중에살거.png` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=뷰티 제품 후보
- `memo_화장품살때참고하려고.jpg` gold=['memo'] | V14 intents=['memo'] review=False cat=쇼핑 후보 | V15 intents=['memo'] review=False cat=쇼핑 후보
- `schedule_todo_비행기스케줄.jpeg` gold=['schedule', 'todo'] | V14 intents=['memo'] review=False cat=여행 일정 | V15 intents=['memo'] review=False cat=여행 일정
- `schedule_todo_수강신청꼭해야지.jpeg` gold=['schedule', 'todo'] | V14 intents=['memo'] review=False cat=대외활동 | V15 intents=['memo'] review=False cat=대외활동
- `schedule_todo_친구공연장장소와시간.jpeg` gold=['schedule', 'todo'] | V14 intents=['memo'] review=False cat=공연 정보 | V15 intents=['memo'] review=False cat=공연 정보
- `schedule_공차할인날짜시간.jpeg` gold=['schedule'] | V14 intents=['memo'] review=False cat=쇼핑 정보 | V15 intents=['memo'] review=False cat=브랜드 이벤트
- `schedule_이때집비워야함.png` gold=['schedule'] | V14 intents=['memo'] review=False cat=기숙사 생활 | V15 intents=['memo'] review=False cat=기숙사 생활
- `schedule_제출날짜.jpeg` gold=['schedule'] | V14 intents=['todo'] review=False cat=취업 준비 | V15 intents=['todo'] review=False cat=취업 준비
- `todo_schedule_날짜맞춰서가려고.jpg` gold=['todo', 'schedule'] | V14 intents=['memo'] review=False cat=공연 관람 | V15 intents=['memo'] review=False cat=공연 관람