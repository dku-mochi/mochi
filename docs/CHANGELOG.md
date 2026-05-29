---
level: 3
mode: log
status: active
last_verified: 2026-05-29
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: 모찌 저장소의 의미 있는 변경 이력. append-only log. 최근 변경 맥락이 필요할 때만 읽는다. 분기 마감 시 오래된 항목은 docs/archive/ 로 이관.
---

# CHANGELOG

> 모찌 저장소의 의미 있는 변경 이력. 새 항목은 항상 **맨 위**에 추가한다.
> 범위는 `ios` / `backend` / `docs` / `infra` 중 하나 이상. "왜" 가 자명하지 않으면 한 줄 이유를 덧붙인다.

## 2026-05-29 — ios

- **`dev/mochi` 의 iOS 기능을 현재 트리로 머지** (홈 화면·백탭·LiveActivity·온보딩). 두 코드베이스가 5/25경 공통 베이스에서 갈라진 뒤, `dev` 는 iOS UI/UX 를, 현재 트리는 `capture`→`mochi_item` rename + Gemini 실연결 + 하네스를 발전시켰다. 사용자 결정: **iOS 는 dev 기능을 가져오되 rename(`Capture`→`MochiItem`/`IngestSource`/`IngestChannel`, `captureID`→`mochiItemID`)을 입혀 포팅, 백엔드·문서는 현재 유지.**
  - **홈 화면** (`FeatureInbox`): `HomeView`/`HomeFeature`/`HomeDesign`/`HomeViewMapping`/`RecentMochiCard`/`NeedsReviewCard` — 최근 / 헷갈려요(미분류) / 중요해보여요 3섹션 + quick memo. 4탭 구조(홈/채팅/일정/검색, 채팅·일정 placeholder), `InboxView` 는 설정 내 디버그 진입점으로 강등.
  - **백탭 전체 복원**: `MochiItemSyncWorker` 가 `.screenshot`+단일 이미지를 multipart `POST /mochi_items/back-tap`(신규 `ingestBackTapMochiItem`)로 전송 → Gemini 즉시 분류 결과를 Realm 에 반영(`applyClassification`). LiveActivity(`LiveActivityCoordinator` port@CorePersistence + App `LiveActivityCoordinatorLive` + Widget 좌측 썸네일 컬럼) 가 분석중→ready 후보를 Lock Screen/Dynamic Island 에 표시. `ShareExtension` 백탭/공유 화면(`BackTapShareView`/`ShareEntryView`/`ShareDesign`, 이미지 우선 판정).
  - **Repository 확장**: `MochiItemRepository` 에 `listAmbiguous`/`listByImportance`/`setIntent` 추가(InMemory+Realm). `DailyImportanceAnalyzer`(1일 1회 lazy importance, App Group `daily-importance/` 캐시, GCS 우회 — 현 단계 stub). `SyncTrigger` DI(pull-to-refresh·quick-memo 저장 시 즉시 sync).
  - **온보딩**: `BackTapPage`(펄스/탭카운터/카드 reveal/sparkle)·`AutoSortPage`(3D 카드) dev 정교판 + chroma-key 처리 `iphone_back` 자산. 단축어 등록 URL 은 현재 `shortcuts://` 유지(dev iCloud 링크는 단축어 ID 유효성 확인 필요).
  - **머지 중 추가 수정**: (1) 백엔드 microsecond datetime 대응 `tryParseDate`(현재 `.iso8601` 이 FastAPI `utcnow().isoformat()` 거부하던 버그). (2) 홈·받은기록 카드 탭 → 상세 sheet 연결(`MainTabFeature` 가 `state.detail` 을 세팅하지만 표시 binding 이 없던 dev/현재 공통 미구현 해소). (3) `listAmbiguous` 가 archived/failed 제외(`listByImportance` 와 lifecycle 정합).
  - **검증**: `tuist build Mochi` 성공(40+ 파일 컴파일+link+서명), `CorePersistenceTests` 컴파일+서명 통과, code-reviewer+codex 리뷰 통과(rename 잔재 0·백엔드 계약 일치·DI·로직). 백엔드 변경 없음 — dev iOS 가 호출하는 API 가 현재 백엔드에 rename된 형태로 모두 존재. 기존 테스트 인프라의 Swift 6 strict-concurrency 이슈(`LifecyclePolicyTests` Void-Equatable 은 수정함, `FeatureInboxTests` case-path non-Sendable 은 머지 무관 기존 문제로 별도)는 남음.

## 2026-05-29 — backend, docs

- **Agent 분석 파이프라인을 실제 Gemini agentic loop 로 연결** (핵심 가치 "AI 가 분석한다" 구현). 그동안 `orchestrator` 의 `ANALYZED`/`INDEXED` 노드가 `pass`, 워커는 `_NullLLM`, 스트림 라우터는 `_UnconfiguredLLM` 이라 ingest 된 항목이 분석 없이 `intent=MEMO, summary=None` 으로 남던 도넛 구조를 해소.
  - **Arch2 (LLM = 분석가)**: Gemini 가 `finalizeAnalysis` 로 구조화 분석(summary·intent·secondary·entities·importance·confidence)을 직접 저술하고, 능동 호출 도구는 URL 그라운딩용 `webFetch` 하나. 새 `GeminiAgentClient(LLMClient)` 가 function-calling 루프를 캡슐화(`gemini_classifier.py` 패턴 재사용, `tool_config=ANY` 로 매 turn 진행 강제, `max_steps` 상한).
  - **write-back**: `MochiItemRepository.apply_analysis` + `MochiItemGateway`(agent→mochi_items.application 경계) 로 분석 결과를 row 에 적재 + `entities` 재적재 + lifecycle `INGESTED→ANALYZING→ACTIVE` 확립. `MochiItemResponse` 가 이미 해당 필드를 노출하므로 GET 이 그대로 반영(openapi·iOS 폭포 없음).
  - **모델 = `gemini-3.1-flash-lite` (global)** — 비용 최우선(백탭 분류와 동일). `gemini_agent_model`/`gemini_agent_location` 로 스왑 가능.
  - **Gemini 3 thought_signature echo**: 멀티턴(webFetch 후)에서 직전 functionCall part 에 `thought_signature` 를 되돌려보내야 400 이 안 난다(thinking_budget=0 이어도 필수). chunk→parts→`_to_contents` 로 thread. 라이브(`lab/agent_loop_live_test.py`)로 검증 — text(할 일/지식)·URL(webFetch 그라운딩) 모두 정상 분석, 마감일·토픽 entity 추출 확인.
- **사용자 맞춤형 개인화 프로필** (쓸수록 좋아진다). 최근 입력의 sliding window 에서 "유저 특성 요약(관심사·평소 분류 성향)"을 flash-lite 로 생성해 `user_profiles` 테이블(alembic 0007)에 적립하고, 분석 시 system prompt 에 주입. 워커가 분석 성공 후 디바운스(`profile_refresh_every_n_items` 개마다) 갱신. override 정정은 다음 window 에 자연히 반영. 추상 요약만 저장(raw 미보관) + owner 격리.
- 검증: `make test` 88 passed(+8), `make lint` clean, `make typecheck` 내 코드 0 에러(순부채 35→21), alembic 0007 up/down/up 왕복 무결. (`make openapi` 는 라우트/응답 스키마 무변경이라 byte-identical 예상.)

---

## 2026-05-29 — infra
- **개인 스크린샷 22장 git 히스토리 완전 제거 (`git filter-repo`).** `lab/screenshot/` 의 본인 일상 스크린샷(구매고민·메모 등)이 초기 통합 커밋(이전 `91c0f60`)에 박혀 있었음 → public repo(`dku-mochi`) push 전 개인정보·EXIF 영구노출 차단. 모든 커밋에서 blob 제거(`.git` 88M→32M), `lab/data/` 를 `.gitignore` 에 추가. 스크린샷 실물은 `lab/data/screenshot/`(추적제외)에 로컬 보존하여 팀에 별도 공유. 미커밋 agent 변경 21개는 stash 경유로 무손실 보존.
- **commit-gate ③ 넛지 추가 (`pre-commit-reminder.sh`).** `git commit` 직전 부모 Claude 컨텍스트에 "review/qa 거쳤나? 사소하면 스킵 OK" 리마인더를 주입(차단 아님, `additionalContext`). 근거: 직전 rename 세션이 `code-reviewer`/`qa-validator` 게이트를 조용히 건너뜀(journal §8.1(C)). 강제(②)가 아니라 ③ 가시성만 높인 이유 — review/qa *필요 여부*는 판단 영역(사소한 변경엔 불필요)이라 기계가 대신 못 정한다. lint/typecheck 는 별도(`ship-precheck.sh` §6)라 여기 중복 안 둠. `settings.json` PreToolUse(Bash) 매처에 등록. CLAUDE.md §7 · WORKFLOW.md §1/§4 정합.

## 2026-05-29 — ios
- **`capture` → `mochi_item` rename iOS 완결 (B4).** 40 파일 + 디렉토리/파일 rename + `Project.swift`. 모듈 `FeatureCapture`→`FeatureMochiItem`, 도메인 `Capture`→`MochiItem`, 채널/소스 `CaptureChannel`/`CaptureSource`→`IngestChannel`/`IngestSource`, Realm `RealmCapture`→`RealmMochiItem`, 네트워킹 `CaptureDTO`/`CaptureIngestRequest`→`MochiItemDTO`/`MochiItemIngestRequest`, `ingestCapture`/`getCapture`→`ingestMochiItem`/`getMochiItem`.
  - **wire 계약 정합**: `Citation` `captureID`+`"captureId"` → `mochiItemID`+`"mochiItemId"` (백엔드 CitationDTO 와 일치), URL path `/api/v1/captures`→`/api/v1/mochi_items`.
  - **캡처 행위 vocab 보존** (의미 분리): 백탭 캡처 서브시스템(AppGroup `captures/` 디렉토리·`captureID` pending-file 핸들, AppIntents `CaptureScreenshotIntent`/`CommitBackTapCaptureIntent`/`QuickCaptureIntent`, `screenshotCaptureID`/`memoCaptureID`, `capturedAt`).
  - 검증: `tuist generate` ✔; `tuist build` CoreDomain/CorePersistence/CoreNetworking ✔ (도메인·Realm·wire 모듈 컴파일+링크). 전체 앱 link 실패는 `PerceptionCore.Perceptible`/`SwiftUICore`/`CoreAudioTypes` static-link 환경 이슈(rename 무관) → 사용자 Xcode/`tuist test` 최종 확인.
  - Realm 마이그레이션 불필요(사용자 결정: prod 없음, 앱 삭제·재설치). openapi-check drift 14→12 (iOS captures 계약깨짐 해소, 남은 12=등록된 known-drift).
  - **잔여**: B5(문서 정합 폭포) — backend+iOS 모두 rename 완료됐으므로 이제 unblocked.

## 2026-05-29 — backend
- **`capture` → `mochi_item` rename 백엔드 완결 (B1~B3 묶음).** `capture` = 이미지 캡처 *행위*, `mochi_item` = URL+이미지+링크 통합 *도메인 객체* 로 의미 분리. DOMAIN_DESIGN 의 정규화 모델과 코드 정본을 일치시키고 audit.sh known-drift 를 코드 차원에서 해소.
  - B1 (`f0e3d50`): `app/modules/captures/` → `app/modules/mochi_items/` 디렉토리 mv + 외부 import 갱신.
  - B2 (`076b261`): 도메인/application/infra/presentation/agent/search 식별자 갱신 — `CaptureRepository`→`MochiItemRepository`, `IngestCapture`→`Ingest`, `CaptureChannel`→`IngestChannel`, presentation 스키마 `Capture*`→`MochiItem*`, route prefix `/captures`→`/mochi_items`.
  - **B3 (이 커밋): DB 스키마 정합.** alembic `0006` — 테이블 3개(`captures`→`mochi_items`, `capture_image_refs`→`mochi_item_image_refs`, `capture_outbox`→`mochi_item_outbox`) + FK 컬럼 6곳 `capture_id`→`mochi_item_id` + FTS 인덱스 `ix_captures_fts`→`ix_mochi_items_fts`. ORM `__tablename__`/FK/컬럼/관계속성, SQL 문자열(outbox `pg_notify`/worker/orchestrator/postgres_index) 동기화. `openapi.json` 재생성 — path `/api/v1/mochi_items` 계열로 전환.
  - 보존(결정): `captured_at`/`capturedAt`(캡처 행위 타임스탬프), iOS `captures/` AppGroup 디렉토리, iOS AppIntents(`CaptureScreenshotIntent` 등 = 행위).
  - 검증: alembic upgrade↔downgrade 왕복 무결, `make test` 80 passed, `make lint` clean, `make typecheck` 35건(기존 부채, rename 무관·신규 0).
  - **잔여**: B4(iOS 전체 rename — Tuist regenerate, 사용자 직접 실행) → B5(문서 정합 폭포: DOMAIN_DESIGN §18/257/279, TODO, PRIVACY, gcp-architecture.html). docs 가 backend+iOS 를 함께 서술해 B4 이후로 묶음.
  - 환경 메모: 에이전트 실행 컨텍스트가 Framework Python library-validation 으로 `cryptography`/`numpy` dylib 로드를 거부 → `make openapi` 직접 실행 불가. openapi.json 은 `app.openapi()` 를 그대로 덤프하되 런타임 불필요한 두 패키지만 스텁한 일회성 셰임으로 생성(앱 코드 무변경, generator 출력과 동일). 사용자 터미널에선 `make openapi` 정상.

## 2026-05-29 — infra
- **하네스 v3.1 — lab 경계 ②티어 승격 + harness 변형 의도 명문화 + 에이전트 출력 규약.** 동기: harness 메타스킬 기준 자가점검에서 (a)~(e) 약점 도출. 깨진 세션(thinking block 400) 부분작업을 복구·완성.
  - **(a) `lab-experimenter` 경계를 ③(프롬프트)→②(기계 강제) 승격.** `.claude/hooks/pre-edit-scope.sh` 신설 — PreToolUse(Edit|Write) 에서 payload `agent_type=="lab-experimenter"` 일 때만 대상 경로가 `cwd/lab/` 밖이면 exit 2 차단. **fail-open**(agent_type 빈 값=부모 Claude·타 에이전트는 무조건 통과)이라 부모 편집은 안 막힌다. payload 필드(`agent_type`/`cwd`/절대 `file_path`)와 서브에이전트 내부 exit 2 차단 동작은 lab-experimenter 실띄움으로 **실측 검증**. `settings.json` PreToolUse 에 Edit|Write 매처 등록. CLAUDE.md §1 "기계로 막을 수 있는 걸 ③에 두지 말라" 와의 정면 모순 해소.
  - **(b)** `docs/WORKFLOW.md` §5 에 "왜 에이전트 팀이 아니라 서브에이전트+커맨드+hooks 인가" 변형 의도 3줄 기록 — 다음 세션·팀원이 안 흔들리게.
  - **(c)** 5개 서브에이전트 정의에 공통 출력 규약 추가 — 첫 줄 `## VERDICT: …`, 위치 인용 `상대경로:줄` 통일. WORKFLOW §5.1 신설. 부모 재해석 비용 ↓.
  - **(d)** `qa-validator` 에 점진 검증(incremental) + 경계면 교차 비교(openapi↔iOS shape) 철학 명문화.
  - **(e)** `ship-precheck.sh`·`/ship` 에 "부모 Claude 가 작업 루프 중간 자율 호출 가능" 명시. WORKFLOW §5.2 신설.
  - 부수: WORKFLOW §5.1 예시 경로 `capture`→`mochi_items` rename 반영 (drift 수정), 티어 표 ② 셀에 hooks 추가.

## 2026-05-29 — infra
- **하네스 v2.7 — OpenAPI drift 자동 검사 게이트 (codex 권고 흡수).** 동기: codex 7차 평가가 9점대 보강으로 명시한 "`openapi.json` 기반 iOS generator 를 `/ship` 게이트에 연결해 API drift 를 ⓪/② 로 끌어올리기". 정식 swift-openapi-generator 배선은 시간 비용 큼(post-submission 작업, `docs/l2/aspirational/FUTURE_OPENAPI_GENERATOR.md`) → 그때까지의 **fallback ② 게이트**로 drift 자동 검사 도입.
  - `.claude/scripts/openapi-check.sh` 신설 — `mochi-backend/openapi.json` path 와 iOS `URLSessionMochiAPIClient.swift` 의 endpoint 호출을 양방향 비교. path-parameter `{capture_id}` 와 Swift string interpolation `\(id.uuidString)` 둘 다 `{var}` 로 정규화해 매칭. exit code 1 = drift 발견.
  - `.claude/scripts/ship-precheck.sh` §5 추가 — openapi-check 자동 호출. drift 가 *CHANGELOG 등재(openapi-drift 토큰)* 면 warn, *신규* 면 fail. audit 의 STOP 신규/등재 분기와 같은 패턴.
- **openapi-drift 등재 (known-drift)** · owner: 송준서 · since: 2026-05-29 · resolve_by: post-submission: 현재 검출되는 8건 — 의도된 미구현이므로 등재 후 추적. `/api/v1/auth/{apple,dev,google,logout,refresh}` 는 `AuthCoordinator` 가 클라이언트 외부에서 별도 처리 (구조적 분리). `/api/v1/captures/{var}/stream` (스트리밍 채널), `/api/v1/health`, `/api/v1/users/me` 는 데모 핵심 기능 외라 iOS 미호출 — 마감 후 재검토. 신규 endpoint 가 추가되면 같은 게이트가 fail 로 잡음. **2026-05-29 capture→mochi_item rename(B1~B3) 이후 갱신**: openapi.json path 가 `/api/v1/mochi_items` 계열로 전환돼, iOS 가 아직 호출하는 `/api/v1/captures{,/{var}}` 가 "client-only" drift 로 잡힌다(현재 총 14건). B4(iOS rename) 에서 iOS 가 `/mochi_items` 로 전환되면 해소 — 그때까지 의도된 중간상태.

## 2026-05-29 — infra
- **하네스 v3.0 — CI 실행권한 영구화 + 정적 검사 게이트 통합.** 동기: codex 10차 rubric 평가가 (a) "hooks 실행권한이 CI 검사 기준과 어긋남 — pre-bash.sh, session-start.sh 가 executable 아님 → 로컬 통과/CI 실패", (b) "make lint/typecheck 자동 미포함 — 핵심 품질 게이트 일부 사람 절차" 를 가장 큰 약점으로 지목.
  - 모든 `.claude/hooks/*.sh`, `.claude/scripts/*.sh` 의 실행권한을 `git update-index --chmod=+x` 로 영구 박음. mode 100755 git index 확정. CI 의 실행권한 검사 step 정합. **로컬-CI 불일치 0.**
  - `.claude/scripts/ship-precheck.sh` §6 추가 — `mochi-backend` 의 `make lint` + `make typecheck` 자동 호출. 환경 미설정(`command not found`/`No module`) 은 warn 으로 친절히 구분. 실제 위반은 mark_fail. 사람 절차 → 자동 게이트.

## 2026-05-29 — docs
- **mochi_item known-drift — 임시 정본 표명.** owner: 송준서 · since: 2026-05-27 · resolve_by: W4 sprint. `docs/DOMAIN_DESIGN.md` 머리에 임시 결정 박스 추가 — "코드 변경 없이 문서가 코드(`capture`)를 따라간다, 본 문서의 `mochi_item` 은 논리 모델 설명으로 읽는다." `audit.sh` 의 강등은 W4 결정까지 의도된 정직 신호로 유지. 데모데이 직전 폭발 위험 가시화 + 결정 압박.

## 2026-05-29 — infra
- **하네스 v2.9 — CI 게이트 통합 + audit grep 범위 확장.** 동기: codex 9차 평가가 (a) "hooks 일부는 실행권한/호출방식까지 CI 에서 재검증해야 이식성 완전히 닫힘", (b) "audit grep 신뢰도 강등이 오탐·과소탐 가능성" 을 지적.
  - `.github/workflows/ship-precheck.yml` 신설 — main push / PR 머지 시 자동으로 6단계 ship-precheck 재실행. 실행권한 확인 step + audit + iOS 경계 + OpenAPI drift (등재 known-drift 분기) + ship-precheck 종합. 로컬과 CI 양쪽에서 같은 게이트 강제 — 이식성 완전화.
  - `.claude/scripts/audit.sh` `COMMITTED_RULES` 확장 — `IngestCapture`(BE), `on_device_detection`(iOS), `WebFetch`(BE) 추가. 5건 → 8건. 의미 식별자 커버리지 ↑ (codex 의 "audit 의 grep 신뢰도 한계" 부분 보강).

## 2026-05-29 — infra
- **하네스 v2.8 — 게이트 무결성 강화 + known-drift 메타 컨벤션.** 동기: codex 8차 평가가 (a) "openapi-check.sh 가 read-only sandbox 에서 here-doc temp file 실패 후 0/0 으로 통과 — P1 게이트 무결성 결함", (b) "known-drift 가 정직 등재에 그치면 방치 — owner/date/해소 조건 필요" 를 지적.
  - `.claude/scripts/openapi-check.sh` 의 python heredoc 제거. 별도 파일 `.claude/scripts/lib/extract_paths.py` 로 분리 (read-only sandbox 임시파일 의존 0). exit code 3/4/5 로 환경 오류·입력 손상 명시 구분. **sanity 검사**: spec/client 둘 다 path 0 개면 추출 손상 의심 → exit 5 (절대 통과 표시 안 함). PoC — `extract_paths.py` 일시 제거 시 mark_fail 정상 표면화.
  - `.claude/scripts/ship-precheck.sh` §5 보강 — openapi-check 의 exit code 분기 (`0=pass / 1=drift 분기 / 기타=mark_fail`). 조용한 실패 절대 안 통과.
  - **known-drift 메타 컨벤션 신설** — CHANGELOG known-drift 항목에 `owner / since / resolve_by` 메타 강제 (예: `owner: 송준서 · since: 2026-05-29 · resolve_by: post-submission`). 미해결 방치 회피. `openapi-drift` 항목에 즉시 적용.

## 2026-05-29 — infra
- **하네스 v2.7 — OpenAPI drift 자동 검사 게이트 (codex 권고 흡수).**

## 2026-05-29 — infra
- **하네스 v2.6 — HARNESS_GUIDE 통합 후 정합 + 경고 피로 완화.** 동기: codex 6차 평가가 (a) "HARNESS_GUIDE.md 에 '루트는 git 이 아님' 잔재 — 죽은 문서 냄새", (b) "ship-precheck 가 known-drift 를 warn 으로 통과 → 장기화 시 경고 피로" 를 지적.
  - `docs/HARNESS_GUIDE.md` §3 구조 트리 — "별도 git" → "모노레포 통합 완료", 루트 `.git` 명시. "꼭 기억할 것" 박스도 통합 후 사실로 갱신. 죽은 표현 0.
  - `.claude/scripts/ship-precheck.sh` — known-drift 등재 후 경과 일수 자동 계산. **7일↑ 미결**이면 단순 warn 대신 "결정 압박" 메시지 + `/sprint-end` 권장. 정직한 압박 — 차단은 아니지만 무한 warn 회피.

## 2026-05-29 — infra
- **하네스 v2.5 — 모노레포 git 통합 + ship-precheck here-doc 제거.** 동기: codex 5차 평가가 (a) "루트 git 미통합 — `.claude/`, `docs/`, `journal/` 변경 추적·배포 단위 약함" (4차에서도 반복 지적), (b) "ship-precheck 가 here-doc 임시파일 실패 메시지 + 최종 통과 — 게이트 신뢰성 흠" 을 지적.
  - `mochi-ios/.git`, `mochi-backend/.git` 제거 → 루트 `git init`. 첫 커밋 `91c0f60` 으로 모찌 *전체* 가 단일 git 으로 통합. `.claude/`, `docs/`, `journal/`, `lab/` 모두 처음으로 버전 관리. 하위 git history 는 의도적 폐기 (사용자 명시 허가).
  - `.claude/scripts/ship-precheck.sh` here-doc(`<<DRIFT_LIST_END`) 제거 — `IFS=$'\n'` 로 줄 단위 직접 순회로 교체. read-only sandbox 임시파일 의존 0.
  - `ship-precheck.sh` §5 갱신 — 통합 후 루트 git status 한 번만 검사. 통합 *전* 폴백 분기 보존 (방어적).
  - `AGENTS.md`, `docs/WORKFLOW.md` §10, `.claude/agents/code-reviewer.md` — "통합 전/후 분기" → "통합 완료" 로 정리. codex 호출도 루트 한 번으로 압축.
- **하네스 v2.4 — iOS ②티어 + aspirational 분리 + STOP 등재/신규 구분.** 동기: codex 4차 평가가 (a) "openapi.json → iOS 생성 ⓪ 미완성", (b) "ship-precheck 가 audit STOP 을 warn 으로 두고 통과 — 차단력 약함", (c) "iOS 레이어 규칙 ③ — Tuist graph/import scan 같은 ② 게이트 필요", (d) "6/7필드 표현 잔재" 를 지적.
  - `.claude/scripts/ios-boundaries.sh` 신설 — iOS TCA 레이어 자동 게이트 (Features 간 직접 import / Cores → Features 역방향 / @main 위치). ③ → ② 승격. `ship-precheck.sh` §4 가 자동 호출.
  - `.claude/scripts/ship-precheck.sh` 보강: STOP 후보를 *등재된 known-drift(audit drift + CHANGELOG token)* vs *신규* 로 분기 — 신규만 ❌ fail, 등재는 ⚠️ warn. cascade paralysis 회피와 차단력 강화 양립.
  - `docs/l2/aspirational/FUTURE_OPENAPI_GENERATOR.md` 신설 — iOS OpenAPI generator 배선 계획. `target_milestone: post-submission` 명시. 정직성 ↑ + sprint-end cut 후보로 자동 추적.
  - `docs/WORKFLOW.md` §8 갱신 — "iOS 자동검출 없음" → "ios-boundaries.sh 가 ② 자동 검출". 자기 룰 정직화.
  - `docs/WORKFLOW.md` §12.1 + `.claude/hooks/post-edit-md.sh` — "6필드" 잔재 모두 "7필드" 로 통일.
  - `CLAUDE.md` §7 — hooks 와 scripts 목록 보강 (post-edit-md / stop-summary / audit / ship-precheck / ios-boundaries 모두 등재).

## 2026-05-29 — infra
- **하네스 v2.3 — 게이트 무결성 + 이식성 강화.** 동기: codex 3차 평가가 (a) "audit.sh here-string `<<<` 가 read-only sandbox 에서 temp file 만들다 실패", (b) "**ship-precheck 가 audit 실패를 `|| true` 로 삼키고 통과 표시 — 게이트 무결성 결함**(가장 큰 단일 약점)", (c) "settings.json·hooks 절대경로 이식성" 을 지적.
  - `.claude/scripts/audit.sh` — `IFS read <<<` 를 `printf | awk -F'|'` 필드 파싱으로 교체 (here-string 제거, subshell 안전, read-only 호환).
  - `.claude/scripts/ship-precheck.sh` — `|| true` 제거 + `audit.sh` exit code 명시적 검사. 실패 시 mark_fail + audit 출력 첨부. **게이트 무결성 결함 해소.** PoC: 가짜 실패 스크립트(exit 17) 가 mark_fail 로 정상 표면화.
  - `.claude/settings.json` — hook command 의 절대경로 → `"${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/X.sh"` 패턴. CLAUDE_PROJECT_DIR 우선, fallback PWD.
  - `.claude/hooks/{session-start,stop-summary}.sh` — `REPO=` 하드코딩 제거. 스크립트 위치 기준 자동 추론 + `CLAUDE_PROJECT_DIR` 우선.

## 2026-05-29 — infra
- **하네스 v2.2 — 자동화 범위 확장 + 7필드 정합 + 이식성.** 동기: codex 2차 평가가 (a) "audit 외 핵심 의식은 여전히 문서", (b) "audit.sh 의 macOS-only `date -j` / `bc` 의존성 + hardcoded path", (c) "grep drift 검출 범위 좁음 (mochi_item 케이스만)", (d) "6필드 vs 실제 7필드 모순", (e) "HARNESS_GUIDE 에 owners 없음", (f) "루트 git 미통합" 을 지적.
  - `.claude/scripts/audit.sh` 갱신: ① hardcoded path 제거(스크립트 위치 기준 REPO 자동 추론). ② `date` portable 분기 (macOS `-j -f` ↔ Linux `-d`). ③ `bc` 제거(awk 산술로 대체). ④ `COMMITTED_RULES` 배열로 drift 검사 패턴 외부화 + 확장(`LifecyclePolicy`, `Idempotency-Key`, `CaptureRepository`, SSRF 추가). ⑤ front-matter 누락 검사를 7필드(level/mode/status/last_verified/confidence/owners/description) 로 정합.
  - `.claude/scripts/ship-precheck.sh` 신설 — `/ship` 의 자동 사전 체크 엔진. (1) audit STOP/drift 정확 추출, (2) CHANGELOG 오늘 항목, (3) CLAUDE↔AGENTS mtime 5분 임계, (4) 하위 repo git status. `/ship` 절차의 *문서* 와 *실행* 을 분리.
  - `.claude/commands/ship.md` §0 추가 — "자동 사전 체크 (반드시 먼저): bash .claude/scripts/ship-precheck.sh". `/audit` 와 같은 분리 패턴 적용.
  - `docs/WORKFLOW.md` §12.1 정정 — "6필드" → "7필드" (`owners` 포함 정직화). `.claude/hooks/post-edit-md.sh` 표현도 동기화.
  - `docs/HARNESS_GUIDE.md` front-matter 에 `owners` 추가 (모든 docs front-matter 7필드 완비).
  - `.gitignore` 신설 — 루트 모노레포 통합 PR 의 초석. `.env*`, 빌드 산출, Python 캐시, Tuist derived, macOS `.DS_Store`. 통합 시 즉시 활성화.

## 2026-05-29 — infra
- **하네스 v2.1 — 자동 채점 결정론화.** 동기: codex 평가 (자체 1차) 가 "검증이 명령 *문서* 수준" 을 가장 큰 단일 약점으로 지목. `/audit` 의 명령 문서 + 실제 bash 스크립트 분리, 자동 grep 정합성 강등 동작 확인.
  - `.claude/scripts/audit.sh` 신설 — `/audit <l1|l2|l3|all>` 의 실제 실행 엔진. front-matter 추출 → 시간 강등(L1 60일/L2 30일/L3 14일) → L2 committed 의 코드 식별자 grep 강등 → STOP 후보 자동 식별. **dry-run 확인**: `DOMAIN_DESIGN.md` 의 `mochi_item` 활성 known-drift 가 자동으로 confidence 0.5 → 0.20 강등 + STOP 후보로 표시. 사람 손 없는 ②티어 자동 채점.
  - `.claude/hooks/post-edit-md.sh` 신설 — PostToolUse on `Edit|Write`. `.md` 파일에 front-matter 6필드 누락 시 *알림*만 (차단 X — cascade paralysis 회피). description 길이 sanity 도 검사.
  - `.claude/hooks/stop-summary.sh` 신설 — Stop hook. (a) 오늘 docs 변경이 있는데 CHANGELOG 오늘 항목 부재 시 알림, (b) `CLAUDE.md` mtime 이 `AGENTS.md` 보다 5분↑ 앞서면 `/sync-agents` 알림.
  - `settings.json` hooks 에 PostToolUse + Stop 추가 (SessionStart + PreToolUse 와 함께 4-hook 시드 완성).
  - `.claude/commands/audit.md` 갱신 — "실제 실행 엔진은 .claude/scripts/audit.sh" 명시. 명령 문서 ≠ 사람 가이드.
- **팀 합의: 루트 모노레포 git 통합 예정.** 동기: 현 분리(루트 = non-git, mochi-{ios,backend} 만 각각 git) 가 (1) `.claude/`·`docs/`·`journal/` 등 운영 파일을 버전관리 밖으로 두고, (2) codex review 를 양 하위 repo 에서 따로 돌려야 해서 두 프로젝트에 걸친 변경의 정합성 검증 비용을 올리며, (3) 팀원이 git 으로 하네스를 못 받음. 통합 시점에 하위 git history 보존 방식(subtree merge / replace) 결정. 통합 PR 전까지는 convention 유지.
  - `AGENTS.md` "모노레포 git 컨텍스트(전환 중)" — 현재·통합 후 상태 둘 다 명시.
  - `docs/WORKFLOW.md` §10 — "팀 합의 대기 중" → "팀 합의: 통합 예정".
  - `.claude/agents/code-reviewer.md` — codex 실행 위치를 통합 전/후로 분기.

## 2026-05-29 — infra, docs
- **하네스 v2 구축 — 2달 단기 모드 + AI-friendly 문서 + hooks 도입.** 동기: 경진대회 산출물 제출 2026-07-15 (8주) 까지의 라이프사이클을 한 호흡으로 통합. codex 자문 반영 (cascade paralysis 회피 + 자동 채점 없으면 메타데이터 장식화 회피).
  - **`.claude/settings.json` 강화**: 박혀있던 죽은 절대경로 (`/Users/lee-y.ch/...`) 제거. `.env` 류 일괄 deny (`Read/Edit/Write(**/.env*)`). 위험 git 명령 deny (`push --force`, `reset --hard`). hooks 시드 도입.
  - **hooks 신설 (`.claude/hooks/`)**: `session-start.sh` 가 경진대회 D-day + 활성 known-drift + 직전 journal 의 "다음 할 일" 출력. `pre-bash.sh` 가 PreToolUse 로 force-push/reset --hard/rm -rf //. env 직접 출력 차단(PoC 동작 검증). ③티어를 ②티어로 승격.
  - **두 축 메타데이터 컨벤션**: `level × mode` (변화율 × 종류). mode = `committed | aspirational | reference | log`. front-matter 6필드 시드(`level, mode, status, last_verified, confidence, owners, description`)로 통일. 적용 docs — `CLAUDE.md`, `AGENTS.md`, `docs/{WORKFLOW, PRODUCT, ARCHITECTURE, DOMAIN_DESIGN, PRIVACY_SENSITIVE_CAPTURE, TODO, CHANGELOG, INDEX, HARNESS_GUIDE}.md`, `journal/README.md`, `DESIGN.md`, `mochi-{ios,backend}/README.md`. description 은 imperative + "When to read" 트리거로 강화 (AI undertrigger 회피, skill-creator 가이드).
  - **`docs/INDEX.md` 신설** (L1 reference): path-first 길잡이 — AI 가 파일 열기 전 path 만으로 load/skip 결정. `docs/archive/**`, `docs/l2/aspirational/**`, 루트 `archive/**` 는 default skip.
  - **`docs/l2/aspirational/`, `docs/archive/` 디렉토리 신설** + 각 README 가 AI 동작 규칙 명시. aspirational 은 반드시 `target_milestone` (K8s "Beta forever" 회피, Node.js Stability 영감).
  - **하위 repo 에 `AGENTS.md` symlink**: `mochi-{ios,backend}/AGENTS.md` → `../AGENTS.md`. codex 가 하위 repo 안에서 실행돼도 같은 규칙을 본다 (code-reviewer 가 `cd <repo> && codex exec` 호출하는 운영 패턴 보강).
  - **신규 슬래시커맨드 2개**: `/sprint-end <W2|W4|W6|submission>` (2주 sprint 마감 의식 — done/expired 이관 + 다음 sprint 목표 1줄 + scope-cut 강제). `/audit <l1|l2|l3|all>` (시간·grep 강등 — 알림만, 차단 X). 분기/반기 cadence 폐기, 2주 sprint × 4회로 압축.
  - **`/handoff` 강화**: codex 검증 결과 + 양 하위 repo `git diff` 요약 자동 수집 컨벤션 추가. 3인 매일 컨텍스트 스위치 마찰 ↓.
  - **`docs/WORKFLOW.md` §11/§12 추가**: 2달 단기 모드 cadence + 메타데이터 컨벤션 정본화. cascade paralysis 회피 5규칙·scope creep·장식 메타데이터 함정 명시.
  - **`docs/.deadline`**: 경진대회 산출물 제출 마감일 단일 원천 (`2026-07-15`). hook 이 매 세션 D-day 출력.
  - **CLAUDE.md §5 갱신**: INDEX·journal 포인터 추가. §7 갱신: hooks 등재 + 신규 슬래시커맨드 등재.
  - **AGENTS.md 본문 확장**: docs 읽기 룰 + 모노레포 git 컨텍스트(하위 repo 에서 codex 실행) + 2달 단기 모드 명시. codex 가 작업 시작 시 어떻게 docs 를 다룰지 자명해짐.
  - **출처 흡수**: Stewart Brand Pace Layering, Gartner Pace-Layered Strategy, OKR(Mission/Objective/KR), Node.js Stability Index, K8s "Moving Forward From Beta", ADR status, GitLab Handbook SSoT, Anthropic skill-creator(progressive disclosure / description=trigger).
- `docs/HARNESS_GUIDE.md` 신설 — 팀원 온보딩용 친절한 입문서로 `WORKFLOW.md`(L1 운영 매뉴얼)의 풀이 버전. 동기: 개발 경험 적은 팀원도 30분 안에 하네스의 출발점·구조·동선·문서 read 룰·슬래시커맨드 사용법을 한 번에 파악할 수 있어야 함. front-matter 시드(`level: 1`, `mode: reference`, `status: active`, `last_verified`, `confidence: 0.8`) 적용 — 향후 `level × mode` 두 축 분리·자동 채점 도입 시 점진 흡수.
- `CLAUDE.md` §5 문서 포인터 표에 `HARNESS_GUIDE.md` 한 줄 추가 (입문 진입점).

## 2026-05-27 — docs, infra
- **AI-native 협업 하네스 구축** (3인 + AI 정합성 통제). 동기: 사람마다·AI마다 갈라질 수 있는 결정(네이밍·API·코드규칙·파일위치 등)을 AI 기반으로 가두기 위함.
  - `.claude/` 신설 — `settings.json`(권한 allowlist) + 서브에이전트 5(`architect`·`code-reviewer`·`qa-validator`·`doc-guardian` read-only + `lab-experimenter` lab/ 한정 write) + 슬래시커맨드 5(`/daily`·`/handoff`·`/ship`·`/sync-agents`·`/codify`). 서브에이전트는 분석·평가·QA 전담, 코드 수정은 부모 Claude 만.
  - `docs/WORKFLOW.md`(L1) 신설 — 정합성 통제 티어(⓪①②③)·문서 레벨 + 정합성 폭포·공유표면·작업 루프(Flow A/B)·네이밍 사전·파일위치 맵·주간 contract-first 킥오프·브랜치 규칙. 시드는 실제 코드/설정 스캔에서 추출.
  - 문서 레벨 도입 — `docs/*` 에 `level:` front-matter(L1 PRODUCT/WORKFLOW, L2 DOMAIN/ARCHITECTURE/PRIVACY, L3 TODO). 상위 변경은 하위로 정합성 폭포.
  - `journal/` 승격 — 하루 로그·인수인계(L3) + 템플릿. 기존 `_workspace/` handoff 2건 이동.
  - `CLAUDE.md` §0/§5/§6 갱신 + §7(하네스) 추가. `AGENTS.md` 를 CLAUDE.md 미러 + codex 검증자 역할로 교체(`/sync-agents` 생성물).
  - codex CLI 설치(npm `@openai/codex`) — `code-reviewer`/`qa-validator` 가 `codex review`/`codex exec` 로 위임.
  - **drift 수정**: `mochi-ios/README.md` 의 OpenAPI 참조 `openapi.yaml` → `openapi.json` (실제 파일명, contract-first 단일원천).
  - 보류: 루트 모노레포 git 통합 + GitHub remote 는 팀 상의 대기. 그 전까지 루트 신규 파일은 버전관리 밖.
- **codex(gpt-5.5) 하네스 리뷰 반영** (하네스 자기 정합성). 동기: 갈라짐을 막을 하네스가 정작 자기 주장과 repo 실제가 어긋남.
  - contract-first ⓪ 티어 과대주장 정정 — iOS 는 `swift-openapi-runtime` 의존성만 있고 generator 미설정 + 수기 `URLSessionMochiAPIClient` → "목표 상태, 현재는 ③ drift 위험" 으로 정직화 (`WORKFLOW.md`·`CLAUDE.md`).
  - iOS 구조 규칙은 자동검출 없음을 명시(③), 백엔드만 ② 경계테스트 강제 (`WORKFLOW.md` §8 + `/codify` 백로그).
  - `settings.json` 에서 `git checkout/switch/stash` 자동허용 제거 (작업 유실 위험).
  - `code-reviewer` 가 루트가 아니라 `mochi-ios`/`mochi-backend` 하위 repo 에서 `codex exec` 하도록 고정 (루트는 git 아니라 diff 못 봄).
  - `WORKFLOW.md` §9 킥오프 문구 정정: `openapi.json` 직접 stub → presentation 스키마/route 추가 후 `make openapi` 생성.
  - `lab-experimenter` 의 `lab/` 경계가 프롬프트 강제뿐임을 명시 + 부모 검증 절차 추가.
- **known-drift 기록 (팀 결정 대기)**: 도메인 문서는 `mochi_item`(정규화 3테이블: mochi_items/mochi_sources/mochi_analyses), 실제 코드/계약은 `capture`(단일 `captures` 테이블) — 같은 엔티티의 이름·구조 동시 divergence. `capture` 는 코드에서 엔티티명 + 캡처 행위/채널을 함께 가리켜 모호. 어느 쪽을 정본으로 할지 미정 → 다음 주 킥오프 결정 후 정합성 폭포 동기화.

## 2026-05-25 — ios
- **백탭 알림 UX prototype 의 Tier 2 + Tier 3 추가** (DEBUG 한정 — `lab/` 실험의 자연스러운 시각화 단계). 사용자 (기획자) 가 "notification center 에 view 띄우는 방향" 을 물어 iOS 알림 UX 의 3-tier (Interactive Notification 액션 / Notification Content Extension custom view / Live Activity Lock Screen+Dynamic Island) 를 조사 후 A+B 결합 prototype 구현 요청. 새 target 3개: `CoreLiveActivity` (ActivityAttributes 의 type identity 를 App + Widget 가 공유하기 위한 작은 framework), `MochiNotificationContent` (`.appExtension` + `UNNotificationContentExtension` + SwiftUI multi-select 후보 view — 알림 펼침 시 알림 안에 후보 체크박스 노출, applicability bar 시각화), `MochiWidgets` (`.appExtension` + `WidgetBundle` + `ActivityConfiguration` + Lock Screen / Dynamic Island compact/expanded/minimal view + iOS 17+ `Button(intent: SelectCandidateIntent)` interactive button). 모찌 본체의 `MockUseCaseNotificationPrototype.scheduleAfterLaunch()` 가 앱 launch 직후 Live Activity (`.analyzing`) 시작 + 10초 후 `.ready` 로 update + 10초 후 Interactive Notification 발송 (페이로드에 후보 3개 + caption + `categoryIdentifier=MOCK_USECASE_V0`). `SelectCandidateIntent` 는 사용자 선택을 App Group 의 `live-activity-selection.json` 에 stash 한 뒤 Activity 를 `.confirmed` → 2.5s 후 dismiss. `OpenMochiOtherIntentIntent` 는 `openAppWhenRun = true` 로 자유 입력 흐름 진입 표현. Mock 데이터는 `lab/intent_v6_compressed_results.json` 의 마우스 케이스 (구매 고민 0.95 / 가격 비교 0.75 / 위시리스트 0.55). App `Info.plist` 에 `NSSupportsLiveActivities=true` 추가 (Activity request 차단 방지). 새 entitlements 두 개 모두 App Group `group.com.IndexFinger.mochi` 공유. **production 진입 아님** — `#if DEBUG` 가드 + 새 target 의 sources 도 prototype 코드만. 끄려면 `MochiApp.init()` 의 `MockUseCaseNotificationPrototype.scheduleAfterLaunch()` 한 줄 주석. 다음 단계 (사용자 결정 대기): (a) Live Activity / Notification Content view 의 시각 디테일 finetune, (b) production 흐름과의 통합 (실제 백탭 → backend Gemini 호출 → 결과로 Activity update + 알림 발송), (c) 도메인 모델 multi-intent 표현 결정 (`journal/2026-05-25-intent-classification-bench.md` §4.2 옵션 A/B/C).

## 2026-05-25 — docs
- **백탭 캡쳐의 LLM 4-Intent 분류 / latency 실험 진행 및 production 권장 spec 도출** (`journal/2026-05-25-intent-classification-bench.md`, `lab/`). 동기: 사용자 (기획자) 와의 토론 중 "백탭의 캡쳐/메모 두 버튼 진입점이 사용자 의도 spectrum 의 거친 표현이 아닌가, 4-Intent 자동 분류 + 사용자 의도 후보 노출 알림 UX 로 갈 수 있을까" 가설 검증 필요. Gemini 3.1 Flash Lite (Vertex AI) 로 사용자 본인 캡쳐 13장에 대해 use case 후보 3개 생성 + 4-Intent 매핑 + multi-intent applicability 점수 측정. **프롬프트 v1→v6 진화** (4-Intent 직접 분류 → use case 후보 생성 reframe → "스크린샷"→"기록 행위" framing → multi-intent 허용 → codex consult 반영해 likelihood→applicability rename + boolean flag 서버 후처리 + JSON 예시 명시) + **이미지 전처리 실험** (5 variant 중 fhd_jpeg_q60 sweet spot — 원본 대비 페이로드 13배 축소 + latency 유지 또는 ↓). 핵심 데이터: (1) **latency p50 ~2.8s** 로 알림 fallback UX 에 충분, (2) **13/13 multi-intent** — 사용자가 한 캡쳐에 여러 의도를 동시에 갖는 게 default 패턴 (마우스 = 구매 고민 + 가격 비교, 이뻐서 = 구매 + 기록 등), (3) **LLM self-confidence 는 모호 케이스 탐지에 부적합** — applicability 분포가 더 정직한 신호. codex 의 권장 5개 중 3개 (필드 명명, boolean 서버 후처리, schema 명시) 는 v6 에 반영, 2개 (few-shot, OCR 등 입력 컨텍스트) 는 후속 작업. **권장 spec**: iOS 측 1920px resize + JPEG q60 → 백엔드 Gemini 3.1 Flash Lite 호출 (v6 prompt + response_schema, thinking_budget=0) → 서버에서 applicability threshold 로 dominant_single / likely_multi / ambiguous_fallback 분기 신호 derive → iOS 알림 UX (default top-1 강조, 펼침 시 multi-select). **도메인 영향은 의도적으로 본 실험 범위 밖** — multi-intent 의 모찌 도메인 표현 (single mochi_item primary + secondary tags vs 1 capture → N mochi_items) 은 별도 결정. 후속: 사용자 정답 라벨링으로 cover rate 정량화, variance 검증, iOS/백엔드 구현 plan + handoff.

## 2026-05-25 — ios
- **snippet 카드 dismiss fix** (`CommitBackTapCaptureIntent.swift`). 사용자 실기 보고: "이 화면 캡쳐" 버튼을 눌러도 카드가 그대로 떠 있어 "아무 일도 안 일어남" 으로 보임. 진단: Realm upsert 와 PNG 영구 이동은 정상 완료 (라이브러리 row 확인). 단지 snippet 카드가 dismiss 되지 않는 게 원인. iOS 17 의 `ShowsSnippetView` + `Button(intent:)` 조합은 자동 dismiss API 가 없다 (iOS 18+ `SnippetIntent` / `dismissesIntent` 가 정식 해법이지만 deployment target = 17.0). `CommitBackTapCaptureIntent.perform()` 의 반환 타입을 `some IntentResult` → `some IntentResult & ProvidesDialog` 로 변경, 세 분기 모두 dialog 반환 (성공 "모찌에 저장됐어요", 실패/invalid "저장하지 못했어요"). 시스템 dialog 가 snippet 카드를 갈음하며 자동 dismiss → 외부 앱 컨텍스트 복귀. 부산물: 이전 silent catch 였던 실패 분기가 사용자에게 가시화 (`docs/TODO.md` §3.4 의 production 직전 alert UI 작업의 일부를 자연스럽게 흡수, 다만 상세 ErrorReporter 인프라는 별도). CHANGELOG 2026-05-25 "snippet 흐름 pivot" 항목의 "알려진 위험 1번 (`Button(intent:)` 가 iOS 17 에서 안정 작동?)" 의 실제 회귀 양상이 fire 가 아니라 dismiss 였음을 확인.
- **`BackTapSnippetView` 시안 B (분할형) 로 재설계 + 다크모드 버그 fix**. 좌측 90×140pt thumbnail + 우측 헤더·세로 버튼 스택 구조. 총 ~165pt 로 WWDC25 권고 340pt height 한계에 여유 (이전 시안 C 는 ~364pt 로 초과해 미리보기 하단이 잘렸음). 다크모드 fix: snippet view 안에선 `@Environment(\.colorScheme)` 가 항상 `.light` 를 반환하는 iOS 18+ 버그 (Apple Developer Forums 783911 / FB17603899) 때문에 `Color.primary` 같은 semantic color 가 다크 디바이스에서 가독성 깨졌다. `Color(uiColor: .label)` / `.separator` / `.systemGray5` UIColor dynamic 으로 통일 — trait collection 기반이라 정상 동작. `mochi-hello` 캐릭터는 60→40pt 로 축소해 우측 영역 정보 밀도 확보.

## 2026-05-25 — backend + ios
- **`make dev` 가 `0.0.0.0` 바인딩하도록 수정** — 같은 Wi-Fi 의 iOS 실기기에서 Mac 의 LAN IP 로 접근 가능해야 한다. 이전 기본값(`127.0.0.1`) 은 시뮬레이터만 동작하고 실기기 호출 시 connection refused (`NSURLErrorDomain -1004`, errno 61).
- **임시 로그인 (`POST /auth/dev`) 추가** — 실기기 dogfooding 용. `environment=local` 외에서는 503(`auth.dev_sign_in_disabled`) envelope 으로 즉시 거부. subject 만 받아 SHA-256 결정론적 UUID 로 `users` 행을 멱등 upsert 하고 자체 access/refresh JWT 발급. `auth_accounts` 는 건드리지 않아 provider CHECK 제약 회피 + 추후 같은 사용자가 Apple/Google 로 정식 가입해도 무충돌. `app/modules/auth/application/dev_sign_in.py` 신설, `UserRepository.upsert_user_with_id` port 메서드 추가, `tests/unit/test_auth_dev_sign_in.py` 4 케이스 (멱등성 + security 헬퍼와 UUID derivation 일치).
- **iOS 로그인 화면에 "임시 로그인 (dev)" 버튼** (`LoginView`, `#if DEBUG` 한정). `AuthCoordinator.signInAsDev(subject:)` 가 `/auth/dev` 호출 → 기존 access/refresh/401 인터셉터/`/users/me` 흐름 그대로 재사용. `AuthProviderKind` 에 `.dev` case 추가. 운영 빌드에는 컴파일 안 됨.
- **실기기용 LAN host 자동 주입** — Tuist `Project.swift` 의 Mochi 타겟에 "Inject Dev LAN Host" post-build script 추가: Debug 빌드 시 `ipconfig getifaddr en0` 결과를 `.app/Info.plist` 의 `MOCHI_DEV_HOST` 키에 PlistBuddy 로 박고 codesign 재적용. `AppDependencies.resolveBaseURL()` 이 그 키를 우선 읽어 `http://<lan-ip>:8000` 으로 baseURL 구성. ATS 는 `NSAllowsLocalNetworking=true` 로 사설 IP 허용. 이전엔 실기기에서 `localhost` 라 백엔드 호출이 불가능했다.

## 2026-05-25 — ios + docs
- **codex 리뷰 P1 3건 + P2 3건 반영** (snippet 흐름의 critical defect). codex 발견 11건 중 **데이터 손실 / corruption 시나리오 6건**을 즉시 fix, 나머지는 docs/TODO.md 로 분리. 반영:
  - **P1 #2 미인증 strand 차단** (`CaptureSyncWorker.swift`): runOnce() 가 `tokenProvider.bearerToken() == nil` 이면 즉시 종료. 이전엔 미인증 사용자가 백탭 → snippet → 캡쳐 → Realm `.pendingUpload` → 다음 launch 의 syncWorker 가 무인증 ingest → 401 → `.syncFailed` 영구 strand. AuthTokenProvider 를 worker init 에 주입 (`MochiApp.init` 에서 `AppDependencies.liveAuthCoordinator` 전달). `MochiApp.swift` 에 `import CoreNetworking` 추가.
  - **P1 #3 메모 분기 새 captureID** (`OpenBackTapMemoIntent.swift`): perform() 이 새 UUID 발급 → marker 파일명에 사용. snippet 의 screenshotCaptureID 는 PNG 폐기에만 사용. 이전엔 메모 commit 이 같은 captureID 로 `.appDirectInput` Realm upsert → `update: .modified` 가 screenshot row 를 silent overwrite (캡쳐 분기 commit 과 메모 분기 commit 이 같은 primary key 충돌). 메모와 캡쳐는 의미상 다른 capture 라는 invariant 반영. parameter 이름도 `captureID` → `screenshotCaptureID` 로 정확화.
  - **P1 #1 commit 실패 시 PNG 보존** (`CommitBackTapCaptureIntent.swift`): commitScreenshot() 성공 시에만 pending PNG 폐기. 실패 시 보존 → `RootFeature.sweepStalePNGs` 의 TTL 이 다음 active 시점에 청소. 이전엔 `try? await commit + 무조건 removeItem` 이라 Realm 실패 시 데이터 손실.
  - **P2 #5 marker-first 순서** (`OpenBackTapMemoIntent.swift`): marker write 성공 확인 후 PNG 폐기. marker 실패 시 PNG 보존 (사용자 의도 흔적 유지).
  - **P2 #9 invalid captureID cleanup** (`CommitBackTapCaptureIntent.swift`): UUID(uuidString:) nil 분기에 pending PNG best-effort delete 추가. silent leak 차단.
  - **P2 #10 pendingFilename 파라미터 제거** (`CommitBackTapCaptureIntent.swift`, `OpenBackTapMemoIntent.swift`, `BackTapSnippetView.swift`, `CaptureScreenshotIntent.swift`): 두 intent 의 `@Parameter pendingFilename` 제거. `AppGroup.pendingBackTapPNGFilename(captureID:)` 헬퍼로 derive. `BackTapSnippetView` 의 `pendingFilename` 필드도 제거 (image preview 로딩도 captureID 로 derive). parameter 신뢰 문제 차단 + plumbing 단순화.
  - **P1 #4 이미지 upload 파이프라인** 은 본 작업 scope 밖 — `docs/TODO.md` §3.5 신설로 분리 (iOS + backend 양쪽 변경 필요한 별도 epic, snippet pivot 이전부터 비어 있던 결함).
  - **defer**: P2 #6 (checkPendingMemo 순서), P2 #7 (TTL race edge case), P2 #8 (AppGroup container nil 처리), P2 #11 (iOS 17 실기 검증 — 사용자 실기 검증 항목). 모두 edge case 또는 기존 알려진 risk.
- **백탭 캡처 경로를 풀스크린 모달 → `ShowsSnippetView` snippet 카드 흐름으로 pivot**. 2026-05-24 의 모달 흐름은 사용자 컨텍스트(예: YouTube)를 빼앗는 UX 문제가 있었다 — Papago 가 쓰는 `ShowsSnippetView` (iOS 17+) 메커니즘으로 외부 앱 위에 작은 카드를 띄워 컨텍스트를 보존한다. handoff `journal/2026-05-24-backtap-flow-handoff.md` §3 (옵션 B) 채택. 변경 요약:
  - `CaptureScreenshotIntent` — `openAppWhenRun = true` → `false`. perform() 반환 타입이 `some IntentResult` → `some IntentResult & ShowsSnippetView`. PNG 를 `pending-backtap/<captureID>.png` 에 stash 한 뒤 `BackTapSnippetView` 를 시스템 snippet 카드로 반환 (모찌 앱 미진입).
  - 신규 `BackTapSnippetView` (`Targets/App/Sources/AppIntents/BackTapSnippetView.swift`) — 외부 앱 위 시스템 카드 SwiftUI view. "캡쳐"/"메모" 두 `Button(intent:)`.
  - 신규 `CommitBackTapCaptureIntent` (`Targets/App/Sources/AppIntents/CommitBackTapCaptureIntent.swift`) — snippet 의 캡쳐 분기. `openAppWhenRun = false`, `isDiscoverable = false`. background 에서 pending → 영구 `captures/<captureID>.png` 이동 + sha256 + Realm `Capture(.screenshot, .pendingUpload)` upsert + pending PNG 폐기. **백엔드 ingest 시도 안 함** — snippet background process 는 `AppDependencies.bootstrap()` 미호출 상태일 수 있어 인증/네트워크 인프라 부재. Realm `.pendingUpload` 가 안전한 fallback (다음 active 시점에 `CaptureSyncWorker` 가 ingest).
  - 신규 `OpenBackTapMemoIntent` (`Targets/App/Sources/AppIntents/OpenBackTapMemoIntent.swift`) — snippet 의 메모 분기. `openAppWhenRun = true`. pending PNG 즉시 폐기 + `pending-backtap/<captureID>.memo` marker stash. 모찌 foreground 진입 → `RootFeature` 가 marker 발견 → `BackTapModalFeature` 메모 phase 모달.
  - `BackTapModalFeature` 메모 전용으로 축소 — `.selecting` / `.capturing` phase 제거, `.memo` / `.savingMemo` 만 유지. `pendingImageURL` State 필드 제거 (메모 분기는 PNG 불필요), `captureID` 만 보관. `commitScreenshot` private helper 와 `Action.captureTapped` / `.captureFinished` 제거. memo marker 폐기 invariant 추가.
  - `BackTapModalView` 메모 전용으로 축소 — selecting/capturing UI 제거. `ScreenshotScanAnimation` overlay 제거.
  - `RootFeature` 로직 갱신 — `.pendingBackTapDiscovered(URL)` → `.pendingMemoDiscovered(UUID)`. `checkPendingBackTap()` → `checkPendingMemo()` (`.memo` marker 가장 최근 한 장 promote). `sweepStalePNGs()` 신설 (launch / scenePhase active 시점에 `.png` 잔재 모두 폐기 — snippet 시스템 dismiss 후 commit intent 미실행 시나리오 대응). `.backTapModal(.dismiss)` 안전망이 marker 폐기로 갱신.
  - `AppGroup` 에 `pendingBackTapPNGFilename(captureID:)` + `pendingBackTapMemoFilename(captureID:)` 헬퍼 메서드 추가. `pendingBackTapDirectoryURL` doc-comment 가 두 파일 종류 (`.png` + `.memo`) 와 snippet 흐름의 invariant 설명으로 갱신.
  - `ScreenshotScanAnimation.swift` 삭제 — snippet 흐름에서는 캡쳐 진행 시각이 외부 앱 컨텍스트 안에서 진행되어 스캔 애니메이션이 의미를 잃음. 내 변경으로 발생한 고아 (CLAUDE.md §3 정리 대상).
  - `InboundQueueConsumer.swift` doc-comment 의 백탭 흐름 설명을 snippet 흐름으로 갱신.
  - `RootView` doc-comment 와 fullScreenCover 코멘트의 "captureFinished" / "pending PNG" 표현을 메모 전용 / marker 폐기로 정정.
  - 단축어 파일 (`/tmp/mochi-backtap-capture-signed.shortcut`) 은 변경 불필요 — 액션 시그니처 (스크린샷 → 이미지 변환 → CaptureScreenshotIntent) 는 동일.
  - 문서: `ARCHITECTURE.md` §1 토폴로지 + §2.2 모듈 그래프 + §2.3 채널 표·노트 + §7 폴더 인덱스 갱신. `PRODUCT.md` §6.3 시나리오 C + §8.9 (모달 → snippet 카드 + 메모 모달). `DOMAIN_DESIGN.md` SQL 주석의 백탭 흐름 설명 갱신. `PRIVACY_SENSITIVE_CAPTURE.md` §7.1 연동 지점이 snippet 분기에 맞춰 두 줄로 분리 (`CommitBackTapCaptureIntent` 캡쳐 분기 OCR vs `BackTapModalFeature` 메모 분기 텍스트 패턴). `mochi-ios/README.md` 입력 채널 표 + App Group 디렉터리 목록 + 모듈 트리 갱신. `docs/TODO.md` §3.0 단축어 가이드를 snippet 흐름 + iOS 17 `Button(intent:)` 검증 필요로 정정. §3.4 에러 핸들링 보강 항목을 `CommitBackTapCaptureIntent` 실패 신호 + snippet 흐름 영향으로 갱신.
- **알려진 위험 / 검증 필요 사항**: (1) iOS 17 실기에서 snippet 안의 `Button(intent:)` 가 안정 작동하는지 — Apple Forum thread/783911 에 일부 렌더링 이슈 보고. 모찌 deployment target = 17.0 이라 critical. (2) `@Parameter String` 두 개 (captureID / pendingFilename) 가 `Button(intent:)` 호출 시 정확히 전달되는지. (3) 백탭으로 호출된 snippet 이 외부 앱 위에 실제로 표시되는지 — Siri/Spotlight 호출 시는 확정이지만 백탭(BackgroundShortcutRunner) 경로는 별도 검증 필요. 모두 사용자 실기 검증 항목 (handoff §3.4).
- **race-guard 추가**: `RootFeature.sweepStalePNGs` 가 TTL 10분 이내 PNG 는 보호 (`pendingPNGTTLSeconds = 600`). 시나리오 — snippet 카드가 외부 앱 위에 떠 있는 동안 모찌 본체가 어떤 이유로 active 가 되면 (`.appBecameActive` 발사) sweep 이 호출된다. TTL 없이 모든 `.png` 를 삭제하면 활성 snippet 의 PNG 까지 폐기돼 사용자가 "캡쳐" 탭한 시점에 `CommitBackTapCaptureIntent` 가 파일을 못 읽고 silent data loss. 10분은 캡쳐가 자주 일어나지 않는 행위라는 점을 고려한 여유 — 사용자가 snippet 보고 잠시 다른 앱 처리 후 돌아와도 활성 PNG 보호. 코드 리뷰 (handoff §3.3) 의 must-fix 후보 M1 해결.
- **`BackTapSnippetView` 디자인 fine-tune** (사용자 피드백 2차 반영):
  - **레이아웃 순서 변경**: 미리보기를 버튼 **아래** 로 이동. snippet 카드가 시스템 max size 를 넘어가면 하단 영역이 잘리는데, 이전 (헤더 → 미리보기 → 버튼) 구조는 결정 UI 인 두 버튼이 가려져 사용 불가 상태가 됨. 새 구조 (헤더 → 버튼 → 미리보기) 는 핵심 결정 UI 가 항상 보이고 미리보기는 "확인용" 이라 잘려도 결정에 지장 없음.
  - **다크/라이트 모드 적응**: 메모 버튼 텍스트를 하드코딩된 navy `#2E3D7D` 에서 `.foregroundStyle(.primary)` (라이트 = 검정, 다크 = 흰색 자동 적응) 로 변경. brand navy 는 다크모드에서 contrast 부족 문제가 있어 시스템 컬러에 위임. brand 그라데이션 (캡쳐 버튼) 은 라이트/다크 둘 다 강한 contrast 라 단일 정의 유지. border opacity 도 0.08 → 0.12 로 약간 강화 (다크모드 visibility).
  - **캐릭터 사이즈**: 42pt → 60pt. brand signal 강화. 미리보기를 200pt 로 줄여 캐릭터 키움 + 버튼 우선 배치까지 모두 카드 안에 들어가도록.
  - **미리보기 max height**: 280pt → 200pt. 잘림 위험 ↓. 사용자가 캡쳐 내용 확인 충분 + 카드 전체 사이즈 적당.
  - **캡쳐된 PNG 미리보기**: `pending-backtap/<captureID>.png` 를 `UIImage(data:)` 로 직접 load. file load 가 snippet redraw 마다 일어나지만 사용자 interaction 빈도 낮아 무시 가능. PNG 없으면 (race 로 sweep 등) 미리보기 영역 자체를 생략.
  - **헤더 폰트 통일 + 한 줄로 축소** — 이전 2-line ("지금 이 화면을" `.subheadline` / "어떻게 저장할까요?" `.title3`) 가 폰트 family/size 가 달라 어색했음. 한 줄 "모찌에 남길까요?" (`.title3 rounded bold`) 로 통일.
  - **카피 정정** — "이 화면을 어떻게 저장할까요?" 는 메모 분기도 화면과 연관된 것처럼 오해를 부름. 메모는 **화면과 무관한 별도 메모**. 헤더 "모찌에 남길까요?" + 버튼 분기: "이 화면 캡쳐" / "새 메모". docstring 정렬.
  - **버튼 라벨 단순화** — 3-line → 1-line (icon + 텍스트).
  - 두 버튼 모두 `.buttonStyle(.plain)` 으로 시스템 wrapping 우회.
  - **추가 import**: `CorePersistence` — `AppGroup.pendingBackTapDirectoryURL` 접근용. AppIntents 가 App 타겟 내부라 의존성 그래프 그대로 통과.
  - **검증 필요** (iOS 17 snippet 영역의 SwiftUI 자유도 가설): (a) `LinearGradient` 가 `Button(intent:)` label 안에서 정상 렌더 ✅ (실기 확인됨), (b) ~~`.ultraThinMaterial` 이 snippet 카드 내부에서 글래스로 보임~~ ❌ (실기 결과 메모 버튼이 검은 박스로 렌더링 — snippet 카드 자체가 시스템 material 이라 그 위에 또 material 깔면 어둡게 합성됨), (c) `Image("mochi-hello")` 가 background process main bundle 접근 ✅, (d) `Image(uiImage:)` + 미리보기가 snippet max size 안에 들어가는가 ✅.
  - **3차 fix — 메모 버튼 visibility 버그 해결**: 사용자 실기 스크린샷에서 메모 버튼이 검은 박스로 보임. `.ultraThinMaterial` 을 `Color(uiColor: .systemGray5)` (dynamic gray, 라이트/다크 자동) 로 교체. 1pt 회색 border 를 1.5pt brand purple stroke 로 강화해 시각 정체성 유지.
  - **4차 fix — 캡쳐 버튼 톤 정렬 (온보딩 일관성)**: 사용자 피드백 "그라데이션 과함, 튜토리얼 색 사용". 캡쳐 버튼 배경을 purple→coral 대각 그라데이션 → **`OnboardingTheme.primary` 단색 `Color(red: 0.55, green: 0.46, blue: 0.93)` + shadow** (`OnboardingButton.swift` 와 동일 톤). 모듈 경계 (`FeatureOnboarding` framework 에서 import 불가능) 로 값 복제 — `brandPrimary` / `brandPrimaryShadow` 정적 상수. `OnboardingTheme.primary` 변경 시 본 view 도 sync 필요 (docstring 명시). 메모 버튼 stroke 도 동일 brand purple 로 통일해 두 버튼이 같은 색 family.

## 2026-05-25 — docs + infra
- `docs/gcp-architecture.html` **MVP reset (DAU 100)** — 초기 안 (DAU 500 · $478/월) 의 over-engineering 을 사용자 지적으로 정리. (1) Cloud Run 4-service 분리 → **1 service + 1 Job** 통합 (FastAPI 한 process 안에 API + SSE + asyncio outbox worker). (2) Cloud LB · Armor · NAT · VPC Connector · Memorystore Redis · Private Service Connect 모두 제거 — Cloud Run domain mapping + Cloud SQL native socket 으로 대체. (3) Cloud SQL `db-custom-2-7680` (HA-ready) → `db-g1-small` (shared 1 vCPU · 1.7 GiB, 10 GB SSD). (4) AI 모델 = **Gemini 3.1 Flash-Lite** ($0.25 / $1.50 per 1M tokens). 후보 비교 (2.5 Flash / 3 Flash / 3.1 Flash-Lite / 3.5 Flash) 결과 가격·속도·최신성 모두 우위 + 사용자 실사용 안정성 확인. (5) **월 비용 $478 → $94** (80% 절감). P1~P4 확장 로드맵 명시 (DAU 200·500·SLA·search-heavy 임계와 비용 증분). 트래픽 가정: DAU 100 · 인당 2 capture/일 · 2 대화/일 = 6K + 6K/월.
- `docs/gcp-architecture.html` 신설 (이전 revision, 위에서 reset 됨) — 모찌 백엔드를 GCP 위에 올린 설계 단일 페이지. 기본 region asia-northeast3 (Seoul), Vertex AI 만 asia-northeast1/us-central1 분기. Cloud Run × 4 (api/sse/worker/housekeeper) + Cloud SQL PG16 (pgvector) + GCS + Vertex AI Gemini 2.0 Flash + 자체 JWT(KMS 서명) 구성. MVP 월 ~$478, 성장기(DAU 2K) ~$1,240 산정. 의사결정 9건과 미결정 8건을 명시 (§7 trade-offs · §9 open questions). 보안·지연·분산·비용 절은 기존 ARCHITECTURE/DOMAIN/PRIVACY 문서의 invariant 와 정합. 단일 정적 HTML — 외부 의존성 없음.

## 2026-05-24 — ios + docs
- **백탭 캡처 경로를 silent 백그라운드 → 풀스크린 모달 (캡쳐 / 메모 선택) 흐름으로 회귀**. 2026-05-23 의 silent pivot 은 원 기획 (`PRODUCT.md` §6.3 · §8.9) 과 어긋난 결정이었음 — 기획자의 의도는 "백탭 → 모달에서 캡쳐/메모 선택 → 캡쳐 시 스캔 애니메이션과 동시에 백엔드 ingest (latency 마스킹), 실패 시 로컬 fallback" 이었다. 변경 요약:
  - `CaptureScreenshotIntent` 가 `openAppWhenRun = true`. perform() 은 PNG 를 `AppGroup.pendingBackTapDirectoryURL/<UUID>.png` 에 stash 만 하고 종료 — inbound queue 적재·sha256 계산 모두 제거 (메모/취소 분기에서 낭비).
  - 새 `AppGroup.pendingBackTapDirectoryURL` (`pending-backtap/`) 추가. inbound queue 와 의도가 다른 단명 stash — 모달이 모든 분기 (캡쳐 / 메모 / 취소 / 비정상 dismiss) 에서 폐기 책임. invariant.
  - 새 `BackTapModalFeature` (TCA, FeatureCapture) + `BackTapModalView` 추가. phase = selecting / capturing / memo / savingMemo. 캡쳐 분기는 pending → captures/ 영구 이동 + `Capture(.pendingUpload)` Realm upsert + `POST /api/v1/captures` 시도. 실패해도 `CaptureSyncWorker` 가 다음 tick 에 재시도 (이것이 "백엔드 + 로컬 fallback").
  - 새 `ScreenshotScanAnimation` (DesignSystem) — 얇은 빛이 위→아래로 1.2초간 통과. 캡쳐 동안 ingest 응답이 더 빨라도 최소 1.2초 보장 (latency 시각 보정).
  - `RootFeature` 가 `.appLaunched` / `.appBecameActive` / `.sessionResolved` / `.login(.signedIn)` 시점에 pending-backtap 디렉터리를 검사 → 가장 최근 PNG 한 장만 모달로 promote, 잔재는 stale 폐기. 미인증 상태에서는 모달 미띄움 (다음 active 시점까지 대기).
  - `RootView` 에 `fullScreenCover(item: $store.scope(...))` + `onChange(of: scenePhase)` 통합.
  - `Project.swift` 의 `FeatureCapture` 에 `CoreNetworking` 의존성 추가 (`MochiAPIClient` 사용 위해).
  - 단축어 파일 (`/tmp/mochi-backtap-capture-signed.shortcut`) 은 변경 불필요 — 액션 시그니처는 동일 (스크린샷 → 이미지 변환 → CaptureScreenshotIntent). `openAppWhenRun = true` 가 자동으로 앱을 foreground 로 띄움.
  - 문서: `ARCHITECTURE.md` §1 토폴로지 다이어그램 + §2.3 캡처 진입 채널 표·노트 + §7 폴더 인덱스 갱신. `PRODUCT.md` §6.3 시나리오 C + §8.9 백탭 모달 사양 정정. `DOMAIN_DESIGN.md` SQL 주석의 백탭 흐름 설명 갱신. `PRIVACY_SENSITIVE_CAPTURE.md` §7.1 연동 지점에 `BackTapModalFeature` 추가.
- **codex 리뷰 1차 반영**: (1) `RootFeature.pendingBackTapDiscovered` 가드 강화 — 활성 모달이 가진 pending URL 과 일치하면 폐기 금지 (concurrent discovery race: `.sessionResolved` + `.appBecameActive` 가 거의 동시에 발사돼 같은 URL 을 두 번 발견하는 시나리오). (2) `RootView` 에 `.interactiveDismissDisabled(true)` + `RootFeature` 에 `.backTapModal(.dismiss)` 안전망 — system-driven dismiss 시에도 pending PNG 폐기. (3) `InboundQueueConsumer.swift` 헤더/`InboundCapturePayload` 코멘트의 stale "CaptureScreenshotIntent 가 큐 적재" 표현 정정 (이제 ShareExtension + QuickCaptureIntent 만 큐 producer). (4) `mochi-ios/README.md` 입력 채널 표 / App Group 디렉터리 목록 갱신 (`pending-backtap` 추가). (5) `docs/TODO.md` §3.0 백탭 단축어 가이드를 silent → 모달 흐름 + 3-액션 (스크린샷 → 이미지 변환 → CaptureScreenshotIntent) 으로 정정 + sandbox extension 한국어 파일명 마찰 우회 사유 명시. (6) `docs/PRIVACY_SENSITIVE_CAPTURE.md` §7.1 의 `BackTapModalFeature` 통합 항목을 "계획 — MVP §8 기준 현재 미통합" 으로 정확화. (7) retry 강도 표현 정확화 (`ARCHITECTURE.md` §2.3, `PRODUCT.md` §6.3·§8.9): "다음 tick 자동 재시도" → "1회 추가 시도 후 `.syncFailed` marking, 자동 retry 종료". (8) `docs/TODO.md` §3.4 신설 — `BackTapModalFeature` 의 pre-upsert vs network 실패 분기, `commitMemo` UI state 유지, `CaptureSyncWorker` `.syncFailed` retry, ErrorReporter 도입을 production 직전 작업으로 기록. (9) NIT: typo `prensentation` → `presentation`, `CaptureScreenshotIntent` 의 unused `import CoreDomain` 제거.
- AppIntent `perform()` 의 fatal crash 수정 (`QuickCaptureIntent.swift:57`, `CaptureScreenshotIntent.swift:67`). 반환 타입이 `some IntentResult` 인데 `.result(value: "저장됨")` 으로 값을 반환해 runtime fatal 발생: `perform() returned types not declared in method signature - Did not declare ReturnsValue but provided one`. 두 Intent 는 큐 적재 / stash 만 수행하므로 `.result()` (값 없음) 로 변경 — 단축어 호출 시 모찌 앱이 즉시 종료되던 문제 해소.

## 2026-05-23 — ios + docs
- codex 3차 리뷰 P1 ×3 정정 (restructure 후 잔여 stale 코멘트). (1) `QuickCaptureIntent` docstring 의 "백탭 화면 캡처는 ShareExtension 으로 일원화" → "백탭은 `CaptureScreenshotIntent` 가 담당" 으로 수정. (2) `DOMAIN_DESIGN.md` 의 "백탭 = ShareExtension → guessChannel" → "백탭 = `CaptureScreenshotIntent` 가 `.screenshot` 직접 할당" 으로 수정 + `guessChannel` 은 외부 공유시트 진입 전용임을 명시. (3) `CaptureChannel.screenshot` 의 한 줄 코멘트를 다중 줄 doc 코멘트로 확장하여 두 할당 경로 (App Intent 직접 vs guessChannel 추론) 모두 명시. 코드 동작 변경 없음 — 모두 docstring/주석 정합화.

## 2026-05-23 — ios + docs
- **AppIntentsExtension 타겟 폐기, AppIntents 를 메인 App 타겟 내부 (`Targets/App/Sources/AppIntents/`) 로 이동**. iOS 16+ 의 `AppShortcutsProvider` 와 그것이 참조하는 `AppIntent` 는 **메인 App 타겟에 있어야** 시스템이 인덱싱한다 (Apple Developer Forums thread/759160, /710552). 이전 구조는 `AppIntentsExtension` 이라는 별도 appExtension 타겟에 `MochiShortcuts`/`QuickCaptureIntent`/`CaptureScreenshotIntent` 가 있어 단축어 앱·"앱과 공유" 리스트·Siri·Spotlight 어디에서도 인텐트가 발견되지 않는 치명적 버그가 있었음. 변경: (1) `QuickCaptureIntent.swift`·`CaptureScreenshotIntent.swift` 를 `Targets/App/Sources/AppIntents/` 로 이동. (2) `Project.swift` 의 `AppIntentsExtension` target 정의(15줄) 및 App 타겟 dependency 의 `.target(name: "AppIntentsExtension")` 제거, 관련 코멘트 3곳 정리 (baseSettings 의 CFBundleVersion 코멘트 / RealmSwift embed script 코멘트 / 하단 AppGroup 상수 코멘트). (3) `Targets/AppIntentsExtension/` 디렉터리 통째 삭제 (Sources 2개·Info.plist·entitlements). (4) `CorePersistence` 의 docstring 4곳 갱신 (`AppGroup.swift`, `InboundQueueConsumer.swift` × 2, `RealmCaptureRepository.swift`, `RealmStoreFactory.swift`) — "ShareExtension·AppIntentsExtension 공유" 표현을 "ShareExtension 공유 (AppIntents 는 App 타겟 내부)" 로. (5) `docs/ARCHITECTURE.md` §1 토폴로지 다이어그램 / §2.2 모듈 그래프 / §2.3 채널 표·새 노트 / §7 폴더 인덱스 갱신. (6) `mochi-ios/README.md` 모듈 트리 / App Group 단락 / 입력 채널 표 갱신. App Group entitlement 는 메인 App 에 이미 있어 AppIntents 의 inbound 큐·`captures/` 쓰기는 그대로 동작. ShareExtension 은 별개 `appExtension` 타겟으로 유지 (NSExtensionPrincipalClass 가 필요한 실제 extension).

## 2026-05-23 — ios + docs
- 백탭 캡처 경로를 ShareExtension → **`CaptureScreenshotIntent` (`AppIntentsExtension`) 직행** 으로 pivot. 이전 결정(ShareExtension 일원화) 의 의도였던 "매 캡처 메모 입력 기회" 는 실 사용 시나리오에서 백탭과 맞지 않다는 발견 — 백탭은 "지금 이 화면" 의도가 이미 명확한 순간 캡처라 한 탭이라도 더 끼면 자동화 가치가 깨진다. Papago 등 third-party 앱이 단축어의 "앱과 공유" 액션 리스트에 노출되는 메커니즘 (이미지 파라미터를 받는 App Intent 가 매칭 게이트) 을 그대로 차용. `CaptureScreenshotIntent` 신설 — `@Parameter image: IntentFile`, `openAppWhenRun = false`, App Group `captures/` 저장 + sha256 + `InboundCapturePayload(channel: .screenshot)` 큐 적재 + "저장됨" 시스템 result dialog. `MochiShortcuts.appShortcuts` 에 두 번째 entry 등록. **세 surface 가 의도적으로 분리**: 외부 공유시트(`ShareExtension` + `ShareEntryView` 메모) / 백탭(`CaptureScreenshotIntent` silent) / Siri·Spotlight(`QuickCaptureIntent` 텍스트). 공통 지점은 `InboundCapturePayload` 큐 포맷만 — "단일 코드 경로" 가 아니라 "단일 큐 포맷". `ARCHITECTURE.md` §1 다이어그램 라벨·§2.3 표·노트, `mochi-ios/README.md` 입력 채널 표/모듈 트리, `docs/TODO.md` §3.0 단축어 액션 구성 (`앱과 공유` → 모찌 → `모찌 화면 캡처`) 갱신. `QuickCaptureIntent` 의 phrase 도 "모찌 캡처" → "모찌 메모 추가" 로 변경 (`캡처` 의미는 `CaptureScreenshotIntent` 가 가져감, 텍스트 Intent 와의 의미 충돌 해소 — codex 1차 finding #10 보강).

## 2026-05-23 — ios
- 온보딩 4페이지 (`AutoSortPage`) 단순화. 라벨 텍스트 ("일정"/"할 일"/"지식"/"기록") 와 `arrow.down` 인디케이터 제거, 4-Intent 아이콘만 한 줄로 배치하고 그 아래 큰 모찌. 텍스트는 이미 타이틀/서브에 있어 hero 슬롯에 중복으로 둘 필요 없음 (시안 단순화). 캐릭터 자산 `mochi-hello` (110pt) → 신규 `mochi2` (220pt, 좌측 손 든 정면 포즈) 로 교체 — 캐릭터 비중 확대로 시각 균형이 아이콘 → 모찌로 자연스럽게 흐름. 아이콘 사이즈 fixed 56pt → `aspectRatio(1) + maxWidth 100` 균등 분배 (≈1.8배 확대, 좁은 디바이스 폭에서 자동 축소). `Assets.xcassets/mochi2.imageset/` 디렉터리 + Contents.json 신설 + `mochi2.png` 배치 완료.
- 온보딩 타이틀 폰트의 `design: .rounded` 제거 (기본 SF Pro). `.heavy` 가 rounded 변형에서는 시각적으로 bold 정도로 약하게 보이던 문제 해결 — rounded 글자 모서리가 stroke 두께를 흡수해 weight 차이가 둔해진다.
- 온보딩 2페이지 (`BackTapPage`) 재조정:
  - 더블탭 애니메이션 속도 중간값으로 (이전 완화안이 과했음). easeIn/easeOut → 전 구간 easeInOut 유지, tap down/up duration 0.20~0.24s, sleep 210~220ms, 마지막 정지 1200ms.
  - 아이폰 압착 효과 제거 — `phoneScale` 프로퍼티와 `scaleEffect` 모두 삭제. 폰 크기는 고정.
  - 손 offset x: -5% → -13% (폰 중심 -20% 기준 +7% 우측). -12° 회전으로 인한 손가락 끝 변위와 합쳐 폰 뒷면 중앙을 조준.
  - 모찌 크기 0.62 → 0.74 (캐릭터 비중 확대), offset x +28% → +30% 으로 미세 이동해 폰과 겹치지 않게 유지.

## 2026-05-23 — ios + backend + docs
- codex 2회 리뷰 반영 (architectural P0 + P1 + 백엔드 contract sync). 미배포·무데이터 상태이므로 마이그레이션 제약 없이 깔끔히 정리:
  - **iOS `CoreDomain.CaptureChannel`** — `.appBackTap` case 완전 제거, `.appIntent` 신설. (백탭 캡처는 ShareExtension 경로에서 `.screenshot` 으로 추론되므로 별도 백탭 채널 케이스 불필요.)
  - **iOS `QuickCaptureIntent.perform`** — `channelGuess: .appIntent` 로 교체 + 빈 입력 차단 (`QuickCaptureIntentError.emptyInput`) + 비어 있지 않지만 `URL(string:)` 실패 시 `.invalidURL(raw)` throw. "모찌 캡처" voice phrase 등으로 의미 없는 row 가 양산되던 문제 차단.
  - **Backend `app/modules/captures/domain/entities.py`** — `CaptureChannel` StrEnum 에서 `APP_BACK_TAP` 제거, `APP_INTENT = "appIntent"` 추가. iOS 가 새 raw value 로 업로드하면 422 받던 contract drift 해소.
  - **`mochi-backend/openapi.json`** — `make openapi` 로 재생성 (iOS 가 swift-openapi-generator 입력으로 사용).
  - **`docs/ARCHITECTURE.md` §2.3** — "단일 코드 경로" 과장 정정 → "단일 큐 포맷" (`QuickCaptureIntent` 는 ShareExtension 추출/UI 우회, inbound 큐 포맷만 공유). 백탭 흐름에 **2-modal 비용** (iOS 공유시트 → 모찌 선택 → `ShareEntryView`) 및 **백탭 신호 채널 소실** 의식적 trade-off 명시. Siri/Spotlight 행 "백그라운드 직행, UI 없음" → "모찌 UI 우회 / 시스템 수준 result dialog 표시 가능" 으로 정확화.
  - **`docs/DOMAIN_DESIGN.md`** — stale `ck_src__channel CHECK` 절 주석 처리 + 현재 backend (`captures.channel String(32)`, validation 은 Pydantic enum) 와 iOS/backend 공통 raw value 목록 명시. 별도 이슈로 `mochi_sources` 스키마 ↔ 실제 `captures` 테이블 drift 노트 추가.

## 2026-05-23 — docs
- 백탭 캡처 흐름을 ShareExtension 단일 경로로 확정. 백탭은 별도 App Intent 가 아니라 사용자가 설치하는 iCloud 단축어가 `Receive Input from Share Sheet → (없으면) Take Screenshot → Share with 모찌` 로 동작하여 기존 `ShareExtensionPrincipal` 로 라우팅된다. 신설 검토했던 `CaptureScreenshotIntent` 는 도입하지 않음 — `ShareEntryView` 가 매 캡처마다 메모/확인 UI 를 제공하여 silent background 보다 "의식적 캡처" 가 AI 분류·검색용 사용자 의도 신호 확보에 유리하고, 외부 입력(공유시트) 과 자동 입력(백탭) 진입을 단일 코드 경로로 통일할 수 있다. `ARCHITECTURE.md` §1 토폴로지 라벨 및 §2.3 입력 채널 표, `mochi-ios/README.md` 입력 채널 표를 이에 맞게 갱신. `docs/TODO.md` 에 iCloud 단축어 제작/공유 URL 발급 체크리스트 추가.

## 2026-05-23 — ios
- 온보딩 3페이지 (`SharePage`) placeholder 를 정식 자산 `mochi-share` 로 교체. 단일 PNG 가 YouTube·Instagram·Safari 아이콘 + 말풍선 + 공유 아이콘 든 모찌까지 모두 포함. 카피 5줄 → 2줄 ("공유 버튼으로도 / 저장할 수 있어요!") 로 축약 — 이미지가 페이지 주연, 텍스트는 보조 (다른 페이지 길이와 균일).
- 온보딩 2페이지 (`BackTapPage`) 사이즈 +20% / 모찌 +40% / 좌측 정렬 재구성. iPhone 0.66→0.78 (offset x:-20%), 손 0.50→0.60 (offset x:-5%), 모찌 0.44→0.62 (offset x:+28%, y:-22%). 우측 빈 공간에 모찌를 배치해 iPhone·손과 가시 영역 분리 (수평 6% 간격, 수직 6% 분리). 모찌는 정적 처리 (애니메이션 제거) — 손가락 더블탭 모션이 학습 포인트라 시선 분산 방지.
- 온보딩 4페이지 (`AutoSortPage`) placeholder 를 정식 자산 `cat-calendar` / `cat-checklist` / `cat-book` / `cat-document` 로 교체. PRODUCT.md §9 의 Intent 매핑 (일정·할 일·지식·기록) 과 1:1 대응. clay-style 3D PNG 로 모찌 캐릭터와 동일 톤.
- 온보딩 2페이지 (`BackTapPage`) 합성·애니메이션 재작업. iPhone 비중 확대 (0.52→0.55) 및 중앙 정렬, 손은 우하단에서 -12° 회전 (손가락 끝이 폰 중심을 향함), 모찌는 등장 전에는 숨김. `@State phase` + `.task` 스리프 루프로 `idle → tap1↓ → tap1↑ → tap2↓ → tap2↑ → reveal` 6단계 더블탭 애니메이션 추가. 탭 시 iPhone 미세 압착(0.97), 두 탭 후 모찌가 spring 으로 튀어오르는 모션. phaseAnimator 대신 명시적 phase state — 3개 레이어 독립 제어가 필요.

## 2026-05-23 — ios
- `FeatureOnboarding` 모듈 신설. 가입 직후 노출되는 4단계 튜토리얼 (`IntroPage` / `BackTapPage` / `SharePage` / `AutoSortPage`) 을 TCA Reducer 로 구현. 1·2페이지는 정식 PNG 자산(`mochi-hello` / `iphone_back` / `hand_tap` / `mochi-jump-shadow`) 을 `Assets.xcassets` 로 import, 3·4페이지는 자산 미도착 상태라 SF Symbols + 컬러 칩 placeholder. 2페이지 "단축어 등록하기" CTA 는 `Environment(\.openURL)` 로 `shortcuts://` 를 열고 콜백에서 다음 페이지로 진행. 백엔드 미배포 상태에서 로그인 흐름을 우회하기 위해 `AppRootContainer` 에 `#if DEBUG` 분기를 두어 디버그 빌드에서만 온보딩을 먼저 표시하고 `OnboardingFeature.State.isFinished` 가 true 가 되면 `RootView` 로 페이드. 릴리스 빌드는 기존 흐름 유지.

## 2026-05-23 — ios
- `Project.swift`: App 타겟에 `Embed RealmSwift.framework` post-build script 추가. realm-swift 는 자체 Xcode project 를 가진 mixed Swift/ObjC 패키지라 Tuist 의 dynamic PackageProduct embed 자동화(`<Name>_<hash>_PackageProduct.framework` 명명 규칙) 에서 빠지고, link 는 되지만 `.app/Frameworks/` 에 RealmSwift.framework 가 누락되어 실기기에서 `dyld: Library not loaded: @rpath/RealmSwift.framework/RealmSwift` 로 즉시 크래시하던 문제 해결. `PackageFrameworks` 산출물을 rsync 로 복사하고 `EXPANDED_CODE_SIGN_IDENTITY` 로 재서명. ShareExtension/AppIntentsExtension 은 부모 .app 의 Frameworks/ 를 공유하므로 App 타겟에서만 embed. baseSettings 의 `ENABLE_USER_SCRIPT_SANDBOXING=YES` 가 이 script 의 DerivedData 접근을 거부하므로 App 타겟에서만 NO 로 override.

## 2026-05-23 — ios
- `Project.swift`: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 을 `baseSettings` 로 끌어올림. 기존에는 App 타겟에서만 정의되어 있어 `AppIntentsExtension` · `ShareExtension` 의 Info.plist 가 참조하는 `$(CURRENT_PROJECT_VERSION)` 이 빈 문자열로 치환되었고, iOS 26.x installd 가 `CFBundleVersion` 검증(`MissingBundleVersion`, MIInstallerErrorDomain 33)에서 거부해 실기기 설치가 실패하던 문제 해결.

## 2026-05-23 — ios
- `Project.swift`: 모든 Feature\* 모듈(`FeatureCapture`/`FeatureInbox`/`FeatureSearch`/`FeatureDetail`/`FeatureSettings`/`FeatureAuth`)에 `Dependencies`, `CasePaths`, `IdentifiedCollections` 패키지를 명시적으로 link. TCA 가 static product 이며 `@_exported import` 로 위 세 패키지 타입(`@Dependency`, `@CasePathable`, `IdentifiedArray`)을 노출하기 때문에, 이를 사용하는 dynamic framework 인 Feature 들에서 `Undefined symbol: Dependencies.Dependency / CasePathsCore.* / IdentifiedCollections.*` linker 에러가 발생하던 문제 해결. App 타겟에 이미 적용되어 있던 동일 패턴을 Feature 레이어까지 확장.

## 2026-05-23 — docs
- 저장소 루트에 `CLAUDE.md` 추가 (Andrej Karpathy 4원칙 + docs 포인터 + 변경 기록 규칙). 향후 Claude 세션이 일관된 작업 원칙을 따르도록 하기 위함.
- `docs/CHANGELOG.md` 신설. 코드/문서 변경의 단일 기록 지점.
