# v18 → v19 개선 플랜 (codex 평가용)

브랜치 `feat/resource-finder-tool`. 라이브 baseline(실스크린샷 39건, `results/baseline_20260614_025147.json`)
이후의 개선 계획. **이 문서는 codex 평가 입력** — 평가 후 최종 플랜으로 확정한다.

## 현재 상태

**등록 tool (`app/modules/agent/infrastructure/registry.py`):**
- `platformContext` — youtube/x/instagram **URL** 메타 그라운딩 (url required, HttpUrl)
- `webFetch` — 일반 URL 본문
- `recoverYoutubeUrl` (신규) — url 없는 youtube 스크린샷 → 무키 검색으로 watch URL 복원
  (`infrastructure/tools/youtube_recover.py`)
- `findReferenceUrls` (신규, 네이버키 조건부) — 네이버+Tavily 검색→critique→judge→티어랭킹
  (`infrastructure/tools/resource_finder.py`), 키워드는 메인이 제공
- system prompt: `prompts/system_prompts.py` classify_and_act **v18** (# Tools 4-tool)

**baseline 진단 (Claude judge, 39장 이미지 직접 채점):**
- tool_choice: correct 30 / miss 4 / wrong_tool 3 / unneeded 2
- finder 16/39 호출, useful 케이스 result_quality 4.6/5
- recover 8/8 유튜브 호출하나 **정확 3 / 빗나감·불확실 5 (평균 2.8)** ← 가장 큰 약점
- none 게이트 견고(과호출 거의 0)

## 개선 항목

### A. platformContext 경계 (사용자 제기: "빼야하지 않을까")
- **현상**: baseline 데이터가 전부 스크린샷(url=null)인데 메인이 인스타/유튜브 스크린샷에
  platformContext 를 환각 url 로 호출 → login redirect/빈 결과(19·26·32·27·3·35). 무의미 + miss/unneeded 유발.
- **단, platformContext 는 url-bearing 캡처(공유시트로 들어온 youtube/insta 링크)의 정본 그라운딩**.
  recover 는 검색 복원, platformContext 는 url 로 직접 oembed → url 있으면 후자가 더 정확. 완전 제거 시 회귀.
- **옵션 A1 (제거)**: registry 에서 platformContext 제외. 단순. url 캡처는 webFetch 로 degrade.
- **옵션 A2 (게이트, 잠정 추천)**: url 이 실제 있을 때만 platformContext. 프롬프트에서
  "url 이 실제 존재할 때만 platformContext/webFetch, url 없는 스크린샷은 recover/finder/none" 명확화.
  (선택) 코드 가드는 불필요 — platformContext.url 이 HttpUrl required 라 메인이 환각 url 을 만들어 넣는 게 문제.
- **codex 에게**: 우리처럼 스크린샷이 지배적인 제품에서 A1 vs A2 어느 쪽이 맞나? url 캡처 비중을 모르는 상태의 보수적 선택은?

### B. recover 정확도 (최우선 — 약점 8건 중 빗나감 5)
- **현상**: `youtube_recover.py` 가 검색 결과 **첫 videoId 를 무조건 채택**. 채널명이 화면에 명확해도
  (너드킹·우연w) 엉뚱한 채널 영상 반환(11·3·13). oembed 로 검증만 하고 선택엔 안 씀.
- **개선안 B1**: candidates(최대 5)의 oembed 를 받아, query 에 담긴 채널명과 `author_name` 이 겹치는
  영상을 고른다(첫 결과 대신 채널 매칭 재랭킹). 매칭 없으면 첫 결과 fallback. 비용: oembed N회(저렴, 무키).
- **개선안 B2 (댓글창 분기)**: 유튜브 댓글창 캡처에서 댓글 본문에 상품 링크(vo.la·무신사 등)가 보이면
  recover(영상 회수) 대신 finder(상품 검색)가 맞다. → system prompt 기준 추가: "댓글에 상품 링크가
  보이면 영상 회수보다 그 상품들을 findReferenceUrls 로". (prompt-criteria: 기준+why, 좁은 예시 나열 금지)
- **codex 에게**: B1 채널 매칭 재랭킹 설계가 타당한가? query 에서 채널명을 어떻게 분리(메인이 채널을
  query 앞에 두는 컨벤션 강제 vs 별도 인자)? B2 는 프롬프트로 충분한가, 코드 신호가 필요한가?

### C. 인스타 행사/예약 + finder local (약점 2·3)
- **C1 (인스타 action-link)**: 무료 예약·신청 마감이 있는 인스타 캡처(남산 페스티벌 등)에서
  platformContext 대신 finder("행사명+예약")로. A2 의 "url 없으면 finder/none" 와 같은 줄기.
- **C2 (finder local)**: 꽃집·소규모 맛집에서 useful=false/공식SNS만(21·27). exp6 부터의 local 약점.
  judge 게이트가 약한 결과를 막아 false positive 는 없음(안전). **후순위** — 무리한 개선보다 깔끔히 none.
- **codex 에게**: C2 를 지금 건드릴 가치가 있나, 아니면 judge 게이트에 맡기고 보류가 맞나?

### D. 재측정
- 개선 후 baseline 재실행(`run_baseline.py`) + Claude judge 재채점. 지표: recover 정확도(3→?),
  tool_choice correct(30→?), unneeded/miss 감소.

## codex 에게 묻는 핵심 4가지
1. A: platformContext 제거(A1) vs url-게이트(A2) — 보수적 최선은?
2. B1: recover 채널 매칭 재랭킹 설계의 타당성·더 나은 방법. query 채널 분리 방식.
3. B2/C1: 댓글창·인스타 행사 분기를 프롬프트로 vs 코드 신호로.
4. 전체: 놓친 위험/과설계/우선순위 오류. divergence 0(정본=lab) 원칙을 깨는 지점은 없나.
