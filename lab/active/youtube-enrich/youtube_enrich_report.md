# 유튜브 메타 추출 실험 — URL → 메타만으로 fallback 회피

> 북극성: **사용자가 직접 해야 할 일을 최대한 줄인다.** 메타(oEmbed 제목·채널 + watch page 전체설명·길이·자막유무)만으로 intent 분류·요약이 되는가, 그래서 사용자 fallback 을 얼마나 피하는가.

> ⚠️ 비용 단가는 추정치(flash-lite, extraction 벤치와 동일). 메타는 전부 무키·공식 경로.

## 핵심 지표

- **메타 추출 성공**: 13/13
- **분석 완료**: 13/13
- **메타만으로 충분(sufficient)**: 13/13 (100%) ← = 사용자 fallback 회피율
- **평균 비용**: $0.000130 / 건  (tok_in 993, tok_out 77)
- **평균 지연**: 2144 ms
- **intent 분포**: knowledge 5, memo 6, todo 2

## 길이대별 충분율 (영상 길이가 변수인가)

| 길이대 | 충분/전체 | 비고 |
|---|---|---|
| shorts(<60s) | 1/1 | |
| mid(1-10m) | 5/5 | |
| long(>10m) | 7/7 | |

## 영상별 상세

| genre | 제목 | 채널 | 길이s | CC | 설명자 | intent | 충분? | 요약 / fallback 이유 |
|---|---|---|---|---|---|---|---|---|
| tech-review | iPhone 16 Pro – 6 Months Later: Long Term … | Andrew Ethan Zeng | 732 | ✓ | 1486 | knowledge | ✅ | 아이폰 16 프로를 6개월간 사용하며 느낀 디자인, 발열, 배터리, 카메라 성능 및 iOS 18 경험에 대한 장기 사용 리뷰 |
| tech-review | iPhone 16 Pro Worth It In 2026? (Review) | Technomentary | 238 | ✓ | 256 | knowledge | ✅ | 2026년 시점에서 아이폰 16 프로의 하드웨어, 소프트웨어 성능을 분석하고 구매 및 업그레이드 가치를 평가한 리뷰 영상 |
| workout | 20 Min Full Body Workout (No Equipment) | MadFit | 1147 | ✓ | 1869 | todo | ✅ | 도구 없이 집에서 20분 동안 수행할 수 있는 전신 운동 루틴 영상 |
| workout | 30 Min Full Body Workout at Home (No Equip… | Oliver Sjostrom | 1929 | ✓ | 145 | todo | ✅ | 집에서 도구 없이 수행할 수 있는 30분 전신 운동 루틴 영상 |
| coding-course | Learn Python - Full Course for Beginners [… | freeCodeCamp.org | 16012 | ✓ | 2211 | knowledge | ✅ | 파이썬 프로그래밍의 기초부터 객체 지향 개념까지 다루는 초보자를 위한 종합 튜토리얼 강의 |
| coding-course | Python Full Course for Beginners | Programming with M… | 22447 | ✓ | 2743 | knowledge | ✅ | 파이썬 입문자를 위한 기초 프로그래밍 강의로, 설치부터 기본 문법 및 실습 프로젝트까지 포함된 종합 학습 자료입니다. |
| travel-vlog | KOREA VLOG🇰🇷: food diaries in seoul, best … | Gelindi 겔린디 | 1664 | ✓ | 1224 | memo | ✅ | 서울에서의 맛집 탐방, 쇼핑, 카페 투어 및 편의점 먹방을 담은 브이로그 영상 |
| mukbang | Korea BBQ Mukbang in Seoul - Korea travel … | Claudia555 | 583 | ✓ | 762 | memo | ✅ | 서울 홍대 캠핑 스타일의 돼지고기 구이 맛집 '육산장' 방문 브이로그 |
| travel-vlog | Seoul KOREA - Myeongdong Shopping Street 2… | Seoul Life | 3620 | ✗ | 254 | memo | ✅ | 2025년 4월 명동 거리의 활기찬 모습을 담은 4K 도보 여행 브이로그 |
| shorts-food | Eating RAW Crab in Seoul 🦀🇰🇷 | CupofTJ | 62 | ✓ | 369 | knowledge | ✅ | 서울 강남구 역삼동에 위치한 간장게장 맛집 '오다리집' 방문 및 정보 공유 |
| shorts-food | What I Ate for Lunch at a High School in K… | Gaezari 게자리 | 38 | ✗ | 341 | memo | ✅ | 한국 고등학교 급식 메뉴를 소개하는 브이로그 시리즈 42번째 영상 |
| music | PSY - GANGNAM STYLE(강남스타일) M/V | officialpsy | 252 | ✓ | 491 | memo | ✅ | 싸이의 대표곡 강남스타일 공식 뮤직비디오 |
| music | BTS (방탄소년단) 'Dynamite' Official MV | HYBE LABELS | 223 | ✓ | 1987 | memo | ✅ | 방탄소년단의 히트곡 'Dynamite' 공식 뮤직비디오 |
