# 유튜브 스크린샷 — 이미지 맥락 추출 + URL 복원

> 북극성: **사용자가 직접 할 일을 최대한 줄인다.** URL 없는 스크린샷에서 [1] 이미지만으로 맥락이 충분한가, [2] 부족하면 단서로 원본 URL 을 복원할 수 있는가.

> ⚠️ 비용 단가 추정치(flash-lite Vision). URL 복원은 무키 youtube 검색→oEmbed. 복원 정확도 = 비전 제목↔복원 제목 키워드 자카드 ≥ 0.3 (근사).

## 핵심 지표

- **표본**: 8 장 (URL 없는 실제 스크린샷)
- **[1] 이미지만으로 맥락 충분**: 7/8 (88%) ← URL 없이 끝나는 비율
- **[2] URL 복원 성공(videoId 찾음)**: 8/8 (100%)
- **복원 정확(제목 매칭 ≥0.3)**: 4/8 (50%) ← 올바른 영상 복원율
- **Vision 평균 비용**: $0.000255/장 (tok_in 1767), 지연 5440ms

## 이미지별 상세

| 파일 | screen | 비전 제목 | 채널 | intent | 충분? | 복원 videoId | 복원 제목 | match |
|---|---|---|---|---|---|---|---|---|
| IMG_8515.PNG | shorts | 벼락 리신 + 릴리아 | @hanoozu | memo | ✅ | E2Qxk3HHT7g | 벼락 리신 + 릴리아 | 1.0 |
| IMG_8516.PNG | shorts | 힘을 숨긴 찐따는 존재하는가 feat. 주짓수 블랙벨트 | @피식대학 | memo | ✅ | 1BLe4-Q6Crs | 힘을 숨긴 찐따는 존재하는가 feat. 주짓수 블랙벨트… | 0.58 |
| IMG_8517.PNG | shorts | 노량진 수산시장 '킹크랩' 1kg 얼마일까?! | @루어갱 | todo | ✅ | N6TME7zfsdw | 노량진 수산시장 '킹크랩' 1kg 얼마일까..?! | 1.0 |
| IMG_8518.PNG | shorts | 자꾸만 오해하게 만드는 송하영 가방 속 물건들 | @하냥냥 | memo | ✅ | y4Cj9EkjF-k | 오해할 만한 비주얼을 가진 송하영 가방 속 물건들 | 0.3 |
| IMG_8519.PNG | shorts | 행사장에서 만난 낯선 꼬마의 정체ㅋㅋ | @예능감각 | memo | ✅ | G2BZDLthtIg | [이선민 vs 조훈] FUNNY GAME: 웃겨봐 / … | 0.0 |
| IMG_8520.PNG | video | Opus 4.8 이제 토큰 한시간만에 다 쓸 수 있음 앙! | @codefactory_off… | knowledge | ✅ | h19erzb5GiA | Opus 4.8 + Ultracode 앙! | 0.17 |
| IMG_8521.PNG | video | Opus 4.8 이제 토큰 한시간만에 다 쓸 수 있음 앙! | @codefactory_off… | knowledge | ✅ | h19erzb5GiA | Opus 4.8 + Ultracode 앙! | 0.17 |
| IMG_8522.PNG | video | nextjs-bug-hunt: Hunt for real bug… |  | knowledge | 🙋 | uGsauG7Btlg | Build an AI Agent Workflow Bui… | 0.04 |

## 케이스 노트 (비전 요약 · 불충분 사유)

- **IMG_8515.PNG** [memo] 리그 오브 레전드 게임 내 리신과 릴리아 조합의 플레이 장면과 데미지 관련 쇼츠 영상
  - 🔗 복원: 벼락 리신 + 릴리아 / 한우주 Hanoozu (query: "한우주 벼락 리신 릴리아")
- **IMG_8516.PNG** [memo] 피식대학의 '사이버 강의' 시리즈 중 '힘을 숨긴 찐따'를 주제로 한 코미디 쇼츠 영상입니다.
  - 🔗 복원: 힘을 숨긴 찐따는 존재하는가 feat. 주짓수 블랙벨트 (수강생: 일오팔, 김원식, 최제우, 정재형) / 피식대학Psick Univ (query: "피식대학 힘을 숨긴 찐따는 존재하는가")
- **IMG_8517.PNG** [todo] 노량진 수산시장에서 킹크랩 구매를 고려하며 시세를 확인하기 위해 저장함.
  - 🔗 복원: 노량진 수산시장 '킹크랩' 1kg 얼마일까..?! / 루어갱 (query: "루어갱 노량진 수산시장 킹크랩 1kg 얼마일까")
- **IMG_8518.PNG** [memo] 프로미스나인 송하영이 가방 속 물건을 소개하며 오해를 불러일으키는 상황을 담은 쇼츠 영상
  - 🔗 복원: 오해할 만한 비주얼을 가진 송하영 가방 속 물건들 / 하냥 (query: "@하냥냥 자꾸만 오해하게 만드는 송하영 가방 속 물건들")
- **IMG_8519.PNG** [memo] 코미디언 조훈이 행사장에서 겪은 웃긴 에피소드를 담은 쇼츠 영상
  - 🔗 복원: [이선민 vs 조훈] FUNNY GAME: 웃겨봐 | EP.01 / 메타코미디클럽 (query: "예능감각 행사장 낯선 꼬마 조훈")
- **IMG_8520.PNG** [knowledge] Claude Opus 4.8 모델의 토큰 사용 효율과 에이전트 기반 버그 헌팅 워크플로우에 대한 기술 영상
  - 🔗 복원: Opus 4.8 + Ultracode 앙! / 코드팩토리 (query: "codefactory_official Opus 4.8 토큰")
- **IMG_8521.PNG** [knowledge] Claude Opus 4.8 모델의 대규모 컨텍스트 처리 성능과 에이전트 활용 사례를 다룬 영상
  - 🔗 복원: Opus 4.8 + Ultracode 앙! / 코드팩토리 (query: "codefactory_official Opus 4.8 토큰")
- **IMG_8522.PNG** [knowledge] Next.js 애플리케이션에서 AI 에이전트를 활용해 버그를 탐색하고 검증하는 워크플로우 화면
  - 🙋 URL 필요: 영상 제목과 채널명이 화면에 명시되지 않아 정확한 출처를 찾기 위해 검색이 필요함
  - 🔗 복원: Build an AI Agent Workflow Builder using NextJs, Mongodb, React, Prisma, Upstash / TechWithEmma (query: "nextjs-bug-hunt meshive AI agents workflow")
