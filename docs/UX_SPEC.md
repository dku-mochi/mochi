---
level: 3
mode: committed
status: active
last_verified: 2026-06-10
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: 화면·시나리오·IA·디자인 톤·데모 시나리오의 committed 정본 (PRODUCT.md L1 에서 분리된 자주 바뀌는 층). 다음 중 하나라도 손대기 전 읽어라 — 화면 구성/플로우 변경, 온보딩·홈·캘린더·상세·ShareExtension UI 작업, 데모 리허설. UI 변경 시 이 문서를 함께 갱신한다 (L3 — 자유 수정, 팀 합의 불요).
---

# 모찌(MOCHI) — UX 스펙

> 제품의 *불변* 정의(미션·문제·4-Intent·UX 원칙)는 [`PRODUCT.md`](PRODUCT.md)(L1) 가 소유한다.
> 이 문서는 그 위에서 **자주 바뀌는 층** — 화면 구성·시나리오·디자인 톤 — 을 소유한다.
> 도메인 의미(intent·lifecycle·동기화 규약)는 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) 참조.

---

## 1. 핵심 사용자 시나리오

### 1.1 시나리오 A — 첫 가입

1. 앱 실행 → 스플래시 → Apple/Google 로그인
2. 온보딩 4단계 (§3.3): 모찌 소개 → 백탭 설정(검증까지) → 공유 저장 → 캡처 자동 정리
3. 홈 진입

### 1.2 시나리오 B — 백탭으로 메모 저장

1. 아이폰 뒷면 두 번 탭 → Shortcuts → snippet 카드에서 "메모" 선택
2. 모찌 풀스크린 메모 모달 → text area 입력 → 저장
3. AI 가 Intent 분류 → 홈의 최근 모찌에 표시

**입력 예시**: "다음 주까지 발표 대본 수정하기"
**AI 결과**: Intent=할 일, 제목="발표 대본 수정", 마감 후보="다음 주"

### 1.3 시나리오 C — 백탭으로 스크린샷 저장 (snippet 흐름)

1. 학교 LMS 과제 화면에서 백탭
2. 단축어가 현재 화면을 자동 캡처 + PNG 를 모찌 stash → 외부 앱(LMS) 위에 모찌 snippet 카드가 떠오름. **LMS 화면은 사라지지 않음** — 사용자 컨텍스트 보존.
3. snippet 카드의 "캡쳐" 버튼 탭 → 카드만 사라지고 LMS 가 계속 보임. 백그라운드에서 로컬 저장(상세 메커니즘·fallback 은 §3.7).
4. 다음에 모찌 앱을 열면(또는 푸시로) 새 캡처가 분석 완료 상태로 떠오름.

**AI 결과 예시**: Intent=일정, 제목="과제 제출", 마감 후보="다음 주 금요일 23:59"

### 1.4 시나리오 D — 유튜브 링크 공유

1. 유튜브에서 공유 버튼 → 모찌 선택
2. Share Extension → URL 수신 → 서버에서 WebFetch / 메타데이터 조회
3. 요약 → Intent 분류 → 지식 또는 기록으로 저장

| 영상 유형 | 분류 |
|---|---|
| LangChain Agent 강의 | 지식 |
| 게임 하이라이트 | 기록 |
| 과제 제출 방법 안내 | 할 일 |
| 행사 일정 안내 | 일정 |

### 1.5 시나리오 E — 자연어 회수

**질문 예시**: "지난주에 저장한 AI Agent 관련 자료 정리해줘."

1. 홈 상단 "모찌에게 물어보세요" 입력바(또는 추천 칩)에 자연어 입력
2. **대화 풀스크린(push)의 첫 메시지**로 전환 (2026-06-10 라우팅 전환 — 칩이 광고하는 추천·수정·요약은 검색 탭이 수행 불가. back 으로 홈에 그대로 복귀)
3. 모찌가 기록을 뒤져 답변 — 본문 위첨자 출처 뱃지(¹²) + 근거 미니카드(탭 → 상세) + 접힌 "과정 보기". 수정/삭제/일정/알림/메모 요청은 proposal 확인 카드로 — 사용자 확정 탭 전까지 아무 일도 일어나지 않는다. 확정 결과는 로컬 미러에 바로 merge 돼 캘린더·홈에 즉시 보이고, 일정 확정은 **실제 iOS 캘린더(EKEvent, 시간 없으면 종일)·미리알림(todo→EKReminder)에도 등록**된다(권한 거부 시 카드가 설정 링크 안내, 재확정 안전 — ingest 멱등)

> 채팅 탭 = **랜딩**(2026-06-10 push 전환 — 입력 독이 탭바 위에 상주하면 이중 바로 읽히고, TabView 안 입력바는 키보드 inset 이 어긋나는 고질 버그가 있다): 모찌 인사 + 능력 칩 4종(홈과 동일 문구) + 입력바 *모양* 버튼(진짜 TextField 아님). 어떤 진입이든 **대화 풀스크린을 push** — 탭바가 사라지고 입력 독이 키보드에 정확히 붙는다(메신저 표준: 카카오톡·X DM). 입력바 버튼 탭 = 활성 세션 복원 + 컴포저 자동 포커스, 칩 = 첫 메시지 즉시 전송, 지난 대화(랜딩·대화 양쪽 시계 아이콘) → 시트(스와이프 삭제, 탭 재개). assistant 버블의 미니 모찌 아바타는 제거(26pt 로 뭉개짐). 세션은 비활성 30분이 지나면 조용히 새 대화로 분리(사용자가 세션을 관리하지 않는다 — 미션). 서버 live 배선 완료(POST-as-SSE + 워치독 75초) — 백그라운드로 스트림이 끊겨도 run 은 서버에서 완주하고, 복귀 시 스냅샷 재조회(+running 2초 폴링)로 "돌아왔더니 답이 와 있다".

---

## 2. 정보 구조 (IA)

탭바 4개. 아이콘만 사용 (VoiceOver label 필수).

| 탭 | 역할 | 상태 |
|---|---|---|
| 홈 | 회수 진입점·주간 리포트·최근 모찌 | ✅ |
| 채팅 | AI 대화 (멀티턴) — 기록 기반 질문·요청이 정체성 (§1.5). 탭 = 랜딩, 대화는 풀스크린 push (§1.5 인용 블록). citation 뱃지·근거 카드·proposal 확인 카드·히스토리 시트·30분 자동분리 | ✅ live 배선 완료(POST-as-SSE·복귀 스냅샷 폴링) + push 구조 전환(이중 바·키보드 가림 해소). 실기기 E2E 검증만 잔여 |
| 캘린더 | 날짜 기반 기록·일정·할 일 | ✅ |
| 검색 | 4 phase 검색·회수 (§3.5) | ✅ 시안 (서버 검색 어댑터 교체 예정) |

입력 경로는 다음 셋으로 통일:
1. 백탭 (Shortcuts)
2. Share Sheet
3. 홈 우측 상단의 작은 입력 버튼

---

## 3. 페이지별 기획

### 3.1 스플래시

- 파스텔 그라데이션 배경 + 모찌 캐릭터
- 카피: "뭐든지 찍어보세요. / 모찌가 기억해둘게요."

### 3.2 로그인

- 모찌 캐릭터 + Apple 로그인 / Google 로그인 버튼 + 약관·개인정보 동의

### 3.3 온보딩 튜토리얼

4단계 (`OnboardingPage`): ① 모찌 소개 → ② 백탭 설정 → ③ 공유 저장 소개 → ④ 캡처 자동 정리 소개 → 홈.

전환: NavigationStack push(좌우 슬라이드) — 스와이프 pager 는 백탭 게이트를 건너뛰게 하고(거부 시 인디케이터 desync) 전환도 끊겨, push 네비게이션으로 바꿨다(전진은 CTA 버튼으로만, 건너뛸 surface 없음). 하단 점 인디케이터 제거, 네비게이션 바는 **배경만 투명**(그라데이션 위에 시스템 뒤로 버튼 노출, 디자인 유지)으로 뒤로가기 제공. 모찌 캐릭터 중심, 텍스트는 한 번에 1~2 문장.

**백탭 설정(단계 ②)은 단순 안내가 아니라 끝까지 끌고 가는 체크리스트다** — 백탭(1순위 입력)은 단축어 *추가* 와 뒷면 탭 *연결* 이라는 분리된 두 행동이 모두 끝나야 살아나므로:
1. **단축어 추가** — iCloud Shortcuts 링크로 모찌 단축어(`Take Screenshot → 모찌 화면 캡쳐`) 가져오기
2. **뒷면 탭 연결** — 설정 가이드 시트가 `손쉬운 사용 > 터치 > 뒷면 탭 > 두 번 탭 > 모찌` 경로를 **실제 설정 화면 스크린샷 세로 캐러셀**(탭할 항목만 스포트라이트로 강조)로 안내
3. **실동작 검증** — 사용자가 실제 뒷면을 두 번 탭하면 App Group 핸드셰이크로 백탭이 모찌 intent 에 도달했음을 확인하고 "백탭이 작동해요"를 모찌가 먼저 알린다(폴링 90초 타임아웃). 검증 중에는 `CaptureScreenshotIntent` 가 진짜 캡처 대신 hit 만 기록해 쓰레기 저장을 막는다 (§3.7).

검증 성공 또는 "나중에 할게요"(skip) 전에는 다음 페이지로 넘어가지 않는다(미설정 채 홈 도착 방지). 온보딩은 첫 실행 때 한 번만 자동 노출하고, 이후에는 홈의 완전 빈 상태와 설정의 "온보딩 다시 보기"에서 재진입할 수 있다. 재진입 온보딩이 끝나면 기존 홈/설정 위치로 돌아간다.

### 3.4 홈

위에서 아래 순서 (`HomeView`):
1. **회수 진입점 (대화 프레임)** — 헤더 "모찌에게 물어보세요"(+서브카피 "답하고, 찾고, 정리해드려요") + 입력바 "무엇이든 편하게 물어보세요"(리딩 아이콘 = 보라 틴트 원 + sparkles, AI 어시스턴트 어포던스) + 추천 칩 4종(찾기·추천·요약·수정 — 채팅의 능력 폭이 칩에서 드러나게). 제출 시 **대화 풀스크린(push)의 첫 메시지**로 전환 (§1.5, 2026-06-10 라우팅 전환 — back 으로 홈 복귀). 검색이 아니라 기록 기반 질문·요청 채팅이 정체성
2. **이번주 리포트 카드** — 주간 저장 개수 + 카테고리별 비중 바 + "이번주 정리 보기" 버튼(주간 돌아보기 진입). 카테고리 라벨은 weekly digest 정규화 결과 반영 (DOMAIN_DESIGN §4)
3. **지금 확인해 주세요** — needsReview("헷갈려요") 항목 버킷. 푸시를 놓쳐도 여기가 진실원천 (있을 때만 표시)
4. **최근에 보낸 것들** — 최근 저장 항목 (12개 limit, 카드 탭 → 상세 zoom 전환)
5. **모찌가 정리하고 있어요** — 분석 진행 중 항목 (기본 접힘)

### 3.5 검색 (회수)

검색 탭은 **4 phase 화면** — `query` 와 `isFocused` 의 조합으로 자동 분기 (시안 #34-36, 2026-06-10 전면 재구현):

| phase | 트리거 | 화면 |
|---|---|---|
| `.idle` | 탭 진입 default (검색바 빈 + 포커스 X) | 출처/타입 필터칩 + 2col 그리드(전체 모찌) |
| `.focused` | 검색바 탭, query 빈 상태 | 모찌(♥) 인사 + 최근 검색 + 빠른 검색(링크/스크린샷/메모) |
| `.results` | 검색어 입력 + 결과 ≥ 1 | Intent 필터칩 + 결과 요약 + 2col 그리드 |
| `.empty` | 검색어 입력 + 결과 0 | 물음표 모찌 + "전체에서 다시 찾기" + "필터 초기화" |

**두 종류 필터** — 검색에선 Intent 가 *주된 분류 단서가 아닐 수* 있어(사용자가 자기 모찌의 의도를 정확히 모를 수 있음 — PRODUCT §5 노출 원칙과 정합) 화면별로 분리:
- 기본 화면(`.idle`) = **출처/타입** 5칩: 전체 / 링크 / 스크린샷 / 메모 / 미확인(needsReview). *어디서 받았나* 의 기억 단서.
- 결과 화면(`.results`/`.empty`) = **Intent** 5칩: 전체 / 일정 / 할일 / 지식 / 기록. 검색 결과를 의도별로 좁힘.
- Intent 분류 자체는 폐기 X — 홈/캘린더/알림의 배관은 그대로.

**카드** — 2col compact thumbnail (height ~138pt). type 별 layout:
- 링크: 제목 → 메타 → mini link preview (favicon + host)
- 스크린샷: preview 박스가 main content
- 메모/미확인: 제목 → 본문 2줄 → 메타

**키보드 ✓ toolbar** — 키보드만 dismiss, 화면 phase 유지(FocusState 와 state.isFocused 분리). `.idle` 복귀는 명시 action(빠른 검색·최근 검색·검색 탭 reselect)으로만. **검색 탭 reselect** — 탭바 검색 탭 재탭 시 filter+query reset → `.idle` 그리드 복귀.

> **배선 상태**: 현재 검색은 디자인 시안 단계 — `SampleMochiItems.designDemo()` 샘플 데이터 위 로컬 매칭(`MockSearchService`, token-contains + intent 필터). **서버 Hybrid Search(`POST /search`) 어댑터로 교체 예정**(동일 시그니처). RAG 자연어 답변 + 근거 모찌 표시는 서버 배선과 함께.

### 3.6 캘린더

날짜 기반 탐색 (`MochiCalendarFeature`):
1. **월간 캘린더** — 칸을 **점 3종(단일 시각 언어)** 으로 칠한다: 일정(sky, active schedule 의 `payload.date`) · 할 일 마감(butter, active todo 의 `payload.deadline ?? payload.date`) · 저장(purple, `capturedAt`). 각 신호당 점 하나 — 개수·대표 intent 색 폐기(2026-06-10, 캡처 intent 색과 마감 마커 색의 한 칸 충돌 제거). 카드 하단 범례와 1:1.
2. **날짜 탭** — 그날 캡처 + 그날 마감/일정 항목을 sheet 로 함께 표시. sheet 셀 탭은 sheet 를 닫지 않고 그 위로 상세를 hero present (닫으면 보던 목록 복귀).
3. **하단 리스트** — ① 다가오는 일정(active schedule, 오늘 이후 빠른 시간순) ② 마감 임박한 할 일(미완료) ③ 완료한 일(접이식, 재토글 가능).
4. **할 일 체크박스** — `active ↔ archived(todoCompleted)` 토글, 서버 `POST .../lifecycle` 로 영속(낙관적 로컬 + 서버 push, 실패 시 롤백). 같은 화면 중복 캡처(같은 제목·라벨·마감)는 **표시에서 하나로 합치되**, 숨은 쌍둥이 instance 도 완료 토글에 함께 전이된다(하나만 완료하면 쌍둥이가 되살아나는 혼란 방지). 주간 돌아보기도 같은 취지로 합치되, 거긴 instance label 이 없어 마감 없는 항목은 합치지 않는다. 도메인 데이터는 합치지 않는다.

### 3.7 백탭 Snippet 카드 + 메모 모달 + 온보딩 검증

**snippet 카드** (`BackTapResultSnippet` wrapper, 외부 앱 위 표시 — 일반 캡처 분기는 `.capture` → `BackTapSnippetView`, 온보딩 검증 분기는 `.verified` → `BackTapVerifiedSnippetView`).

`CaptureScreenshotIntent` 가 `Take Screenshot → 이미지 변환(PNG)` 출력을 받아 PNG 한 장을 `pending-backtap/<captureID>.png` 에 stash 한 직후 `.result(view:)` 로 반환. 시스템이 `ShowsSnippetView` 메커니즘으로 카드를 외부 앱 위에 띄움 — **모찌 앱을 깨우지 않는다** (Papago 패턴). 카드 구성:

- 한 줄 안내 "이 화면을 어떻게 저장할까요?" + 작은 모찌 아이콘
- 두 버튼: **캡쳐** (`CommitBackTapCaptureIntent`) / **메모** (`OpenBackTapMemoIntent`)

**캡쳐 분기** — `CommitBackTapCaptureIntent` (`openAppWhenRun = false`):
- background 에서 pending → 영구 `captures/<captureID>.png` 로 이동 + sha256 계산 + Realm `MochiItem(channel: .screenshot, syncState: .pendingUpload)` upsert + pending PNG 폐기
- **백엔드 ingest 시도 안 함** — snippet background process 는 `AppDependencies.bootstrap()` 미호출 상태일 수 있어 인증/네트워크 인프라 부재 가능. Realm 에 박아둔 `.pendingUpload` 가 안전. 다음 모찌 active 시점에 `MochiItemSyncWorker` 가 ingest 시도 (실패 시 1회 더 retry 후 `.syncFailed` marking — 자동 재시도 종료, 사용자 retry UI 필요, 현재 TODO)
- snippet 카드 자동 dismiss. 외부 앱 그대로.

**메모 분기** — `OpenBackTapMemoIntent` (`openAppWhenRun = true`):
- pending PNG 즉시 폐기 (사용자가 스크린샷 의도가 아님을 명시한 것)
- `pending-backtap/<captureID>.memo` marker 파일 stash
- 모찌 앱 foreground 진입 → `RootFeature` 가 marker 발견 → `BackTapModalFeature` 풀스크린 모달 (`ultraThinMaterial` blur + 모찌 캐릭터 + textarea + 저장 버튼)
- "저장" → `commitMemo` 가 Realm `MochiItem(channel: .appDirectInput, text:)` upsert + `POST /api/v1/mochi_items` 시도 (모찌 앱 안이라 인프라 정상). 실패 시 fallback 은 `MochiItemSyncWorker`.
- "취소" → marker 폐기 + dismiss.

**invariant**:
- `.png` 는 두 commit intent 중 하나가 실행되면 폐기 (캡쳐 분기는 commit 직후, 메모 분기는 marker stash 직전).
- `.memo` marker 는 모달의 어느 정상 분기 (저장/취소) 든 폐기.
- snippet 시스템 dismiss (사용자 외부 탭 / timeout) 후 잔재 (`.png`) 는 `RootFeature` 가 launch / scenePhase active 시점에 sweep.

**온보딩 검증 모드** (일반 캡처 흐름과 분리된 1회성 셋업 절차 — §3.3 단계 ②의 3번째 스텝 "실동작 검증"):

온보딩이 "지금 백탭 해보세요" 단계에 들어가면 `BackTapVerificationClient.begin()` → `AppGroup.beginBackTapVerification()` 이 App Group 파일 마커 `pending-backtap/verify.active` (TTL 120s) 를 연다. 이 창이 열린 동안:
- **진짜 저장을 하지 않는다.** 백탭이 도달하면 진입점이 `AppGroup.markBackTapVerificationHit()` 만 호출 (`verify.hit` 기록 + `verify.active` 즉시 소비) 하고 스크린샷 PNG·`MochiItem` 을 만들지 않는다 — 검증용 백탭이 쓰레기 캡처로 메모리를 오염시키고 잘못된 동작을 학습시키는 것을 막는다.
- **진입점은 두 경로 모두 hit 을 찍는다.** snippet 경로 `CaptureScreenshotIntent` (→ "백탭이 작동해요!" 카드) 와 ShareExtension 경로 `ShareExtensionPrincipal` (→ `BackTapVerifyShareView`). 사용자 단축어가 어느 경로로 흐르든 검증된다.
- **모찌가 폴링해 먼저 알린다.** 온보딩이 `verify.hit` 존재를 폴링(90초 타임아웃), 도달을 감지하면 체크리스트를 완료 처리한다 (미션 "떠오른다" — 사용자가 확인 버튼을 누르는 게 아니라 모찌가 먼저 안다). 감지·타임아웃·단계 이탈 시 `end()` 가 마커를 비운다.

검증은 1회성이라 hit 직후의 일반 백탭은 다시 정상 저장 흐름으로 돌아간다. App 타겟이 `.live` 를 주입하지 않거나 사용자가 단축어를 연결하지 않으면 검증은 감지되지 않고 "나중에 할게요"(skip)로 진행한다 — 의도된 안전 기본값.

### 3.8 모찌 상세

"검수"가 아니라 "회수" — 분류 라벨을 나열해 검수시키지 않고, 다시 알아보고 바로 행동하게 한다 (PRODUCT §1.5 미션·§8 UX 원칙).

구성(정보 위계, `DetailView`):
1. **회수 헤더** — 썸네일(시각 회상) + 정체성 제목(연필 아이콘 탭 → 인라인 교정, 로컬 `userTitle` 오버라이드) + 출처·시간
2. **헷갈려요 배너** — needs_review=true 일 때만, 후보 칩 + "다른 의도"(자연어 재분석)
3. **지금 할 수 있어요** — 분류를 라벨이 아니라 *형태*로: 할 일=체크박스(완료 시 자동 보관), 일정=**일시 헤드라인**("6월 12일 (목) 오후 2:00") + "캘린더 탭에 담아뒀어요" 통지(일시 미상이면 통지만), 링크=원본에서 보기. 의도가 여럿이면 행이 여럿, 하나도 없으면 섹션 숨김
4. **모찌가 정리했어요** — AI 요약(제목과 다른 정보) + 원본(텍스트 인용·내 메모 카드)

("더 자세히" 접힘 섹션은 2026-06-10 제거 — 추출 정보·태그·근거는 회수에 기여하지 않는 내부 디테일이라 노출하지 않는다.)

분류(4-Intent)는 사용자에게 검수용 라벨로 노출하지 않는다 — 화면에는 행동(체크/통지/열기)으로만 드러낸다 (정본: PRODUCT §5 "노출 원칙 — Intent 는 배관이다"). 미확신(needs_review) 시에만 "헷갈려요"로 확인을 청한다.

**진입 전환**: 카드(홈·캘린더 sheet) → 상세는 UIKit 커스텀 **hero(zoom) present** — 카드 frame 을 캡처해 비행 경로를 지정하고, 비행 중 상세 썸네일을 숨겼다 드러낸다. path push 아님.

### 3.9 Share Extension

콘텐츠별 처리:

| 입력 타입 | 처리 경로 |
|---|---|
| 이미지 | 스크린샷 분석 |
| 텍스트 | 메모 분석 |
| 링크 | WebFetch 후 분석 |
| 선택 텍스트 + URL | 텍스트와 링크 통합 분석 |

UI (`ShareEntryView`) — 콘텐츠에 따라 2가지 레이아웃:
- **이미지 우세 모드** (이미지만): 탑바(취소+출처 칩) + 첫 이미지 전체 높이 + 추가 이미지 개수 + 메모 필드(compact) + 저장
- **텍스트/URL 우세 모드**: 탑바 + Preview 카드(URL host 강조·텍스트 인용·이미지 개수) + 메모 필드(펼침) + 저장

메모 필드(`userMemo`, "추가 메모가 있으면 알려주세요")는 분류 시 화면보다 우선하는 1차 의도 증거로 쓰인다 (DOMAIN_DESIGN §3).

### 3.10 분석 진행·완료 피드백 — Live Activity + 알림

캡처 후 분석이 끝난 것을 앱을 열지 않아도 알게 한다. **회수의 능동 주체는 모찌** (PRODUCT §1.5).

**Live Activity — needs_review 전용** (팀 결정 2026-06-09, 진행중/완료 LA 폐기):
- iOS 가 LA 를 직접 시작하지 않는다. **needs_review=true 분석완료 시 백엔드가 push-to-start** 로 background(잠금)에서 LA 를 시작하는 단일 경로 (iOS 17.2+, `la_start` 토큰).
- content-state phase: `.ready`(후보 2~3개 버튼 — **한 탭 선택이 1급 인터랙션**, 앱을 열지 않고 Lock Screen 에서 의도 확정 + "다른 의도"는 앱 진입) → 사용자가 후보를 고르면 위젯이 `reanalyze`(hint=후보)를 직접 호출하고 로컬에서 `.confirmed` 로 전이.
- **전 채널** (스크린샷·링크·텍스트). 확정(needs_review=false)·실패 분석완료는 LA 없이 alert push 로 통지.

**알림 (분석 완료 시 항상)** — 빈도 조절은 OS 알림 설정에 맡기고 모찌가 가르지 않는다. 본문은 iOS 가 truncate 하므로 **요약 1줄**:
- 확정: "이렇게 저장했어요 — <요약>" (탭 → 앱).
- 헷갈려요: "어떤 의도로 남겼나요?" (탭 → 앱, 홈 "지금 확인해 주세요" 버킷으로). **일반 alert 다 — interactive notification 은 채택하지 않는다**(의도 선택은 Live Activity / 앱 내 버킷이 담당).

**실시간 분담**:
- foreground = **SSE 즉시 반영** (분석 끝나는 순간 홈·캘린더 갱신).
- background/종료 = **APNs** (LA push-to-start + 완료 알림). SSE 는 background 에서 소켓이 끊기므로 이 구멍을 APNs 가 메운다.
- 앱 복귀 시 reconcile — background 중 놓친 상태를 1회 동기화.

**always-on fallback**: 알림 권한을 거부하거나 푸시를 놓쳐도, 홈의 **"지금 확인해 주세요" 버킷**(§3.4)이 진실원천이라 헷갈려요 처리는 언제든 앱 안에서 가능하다.

**실패/지연 fallback**: lifecycle `failed` 또는 분석 90s 초과 시 `demoteToManual` → "헷갈려요(의견 없음)" + 직접 분류 + "다시 맡기기"(`requeueForAnalysis`). webFetch 실패 등으로 인한 무한 폴링을 차단하고, 분석이 죽어도 항목이 사용자 손에서 벗어나지 않게 한다.

---

## 4. 디자인 톤

### 키워드
- 말랑함 / 귀여움 / 정돈됨 / 신뢰감
- AI 스럽지만 차갑지 않음
- 생산성 앱이지만 부담스럽지 않음

### 비주얼
- 파스텔 퍼플 / 크림 화이트 / 소프트 민트 / 라이트 피치
- 부드러운 그림자 + 라운드 카드
- 3D clay-like 모찌 캐릭터

### 컬러·토큰

구체 색상값(hex)·타이포·간격의 **정본은 iOS `DesignSystem` 모듈**(⓪티어 단일원천)이다 — 여기 복제하지 않는다. 의미 매핑만 소유:

| Intent | 컬러 계열 | 아이콘 |
|---|---|---|
| 일정 | Lavender / Purple | calendar |
| 할 일 | Peach / Orange | check |
| 지식 | Mint / Green | book |
| 기록 | Sky / Blue | document |

> 캘린더 칸의 점 3종(sky=일정·butter=마감·purple=저장)은 위 Intent 칩 색과 **별도 팔레트** — 한 칸 충돌 회피 (§3.6).

---

## 5. 데모 시나리오

### 데모 1 — 백탭 메모
1. 백탭으로 모찌 호출 → "발표 대본 수정하기" 입력
2. AI 가 할 일로 분류 → 캘린더 할 일 리스트에 표시

### 데모 2 — 학교 과제 스크린샷
1. 과제 공지 캡처 → 모찌에 저장
2. AI 가 마감일 추출 → 캘린더에 마감 점 + 할 일 생성, 완료 체크 시연

### 데모 3 — 유튜브 링크 공유
1. 유튜브에서 공유 → 모찌 선택
2. AI 가 영상 메타데이터 분석 → 지식으로 저장
3. 홈 입력바에서 "AI Agent 관련 자료 찾아줘" → RAG 답변 + 근거 모찌

— 끝 —
