---
level: 3
mode: log
status: archived
last_verified: 2026-05-24
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: 백탭 캡쳐 흐름의 2026-05-24 세션 인수인계 기록. 같은 흐름 작업 재진입 시 또는 백탭 도메인 결정 흔적이 필요할 때만 읽어라.
---

# 백탭 캡쳐 흐름 — Handoff (2026-05-24)

> 다음 세션이 0 부터 이어받을 수 있도록 정리한 인수인계. 대화 흐름의 의도·결정·trade-off·미완 결정·작업 분량·검증 기준을 한 문서에 모은다.

---

## 0. TL;DR (한 화면 요약)

- 백탭 흐름이 오늘 **silent (5월-23) → 풀스크린 모달 (5월-24 회귀)** 로 한 번 더 pivot 했다. 회귀의 이유는 원 기획 (`PRODUCT.md` §6.3 · §8.9) 의 "캡쳐/메모 선택 모달 + 스캔 애니메이션 + 백엔드 + 로컬 fallback" 과 silent 가 어긋났기 때문.
- 회귀 후 **codex 1차 리뷰까지 통과**. must-fix 6 + nit 2 모두 반영. SHOULD-CONSIDER 3건은 `docs/TODO.md` §3.4 로 분리 (production 직전 작업).
- 그러나 작업 막바지에 **더 나은 방향**이 발견됨: `AppIntent + ShowsSnippetView` (iOS 17+) 를 쓰면 **외부 앱 컨텍스트를 보존한 채** snippet UI 를 외부 앱 위에 띄울 수 있음 (Papago 가 쓰는 패턴). 사용자(기획자) 우려 "YouTube 보다가 모찌 앱 떠올라오는 게 싫다" 가 완전히 해소.
- **현재 상태**: 모달 흐름은 작동 가능 상태로 정합 완료. snippet 흐름으로 갈지는 **사용자 결정 대기 중** (옵션 A/B/C 제시됨, 마지막 메시지 참고).

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

| 단계 | 사용자 요청 | 결과 |
|---|---|---|
| 1 | "단축어 앱에 모찌가 안 보임" 진단 | `Metadata.appintents` 추출 정상 확인. "앱과 공유" 액션 picker 가 1st-party 화이트리스트라 모찌 진입 불가임을 확정. 사용자는 단축어 액션 검색에서 모찌 발견 가능. |
| 2 | `.shortcut` 파일 생성 요청 | Python plist 합성 → `shortcuts sign --mode anyone` 으로 서명. iOS 가 unsigned `.shortcut` 의 외부 import 를 차단함을 발견. signed `.shortcut` 으로 우회 성공. |
| 3 | 단축어 실행 시 모찌 앱 fatal crash | `perform()` 의 `.result(value: "저장됨")` 이 `ReturnsValue` 미선언 → `.result()` 로 정정. 두 Intent 모두 수정. |
| 4 | sandbox extension `[22: Invalid argument]` 에러 | `이미지.png` (한국어 locale) path 에 대해 WorkflowKit 이 sandbox token 발급 실패. 단축어에 **이미지 변환(PNG)** 액션 1개 추가로 ASCII 임시 파일명 부여 → 우회. |
| 5 | "캡쳐 완료 후 어떤 화면이 떠야?" | docs/ARCHITECTURE.md (silent) 와 docs/PRODUCT.md (모달) 가 어긋난 상태 발견 → 사용자 기획 재확인. 사용자가 "캡쳐/메모 선택 모달 + 스캔 애니메이션 + 백엔드 fallback" 임을 명확화. silent pivot 이 잘못된 결정이었음을 확정. |
| 6 | **풀 구현** | 코드(7파일) + 문서(5파일) 변경 완료. CHANGELOG 기록. |
| 7 | **codex 리뷰** | must-fix 6 + nit 2 반영. SHOULD-CONSIDER 3건은 TODO §3.4. |
| 8 | "수정 안 한 것 / 수정해야 할 것 분리 설명" | A/B/C 3건이 모두 docs/TODO 로 분리되는 게 정당한 이유 상세 (이 문서 §6 참고). |
| 9 | "로그인 안 된 상태에서 단축어 실행 시 그냥 앱만 열림" | 의도된 동작 (미인증 → 모달 skip + pending 보존). 로그인 후 자동 모달. DEBUG OnboardingView 가 백탭 차단 가능성도 명시. |
| 10 | "ShareExtension 으로 빼면 외부 앱 위에 뜨지 않나?" | 직관은 맞지만 단축어 → ShareExtension 자동 호출이 iOS 안 됨 → share sheet 사용자 탭 1회 추가 → 자동화 가치 깨짐. ShareExtension 방향 비추천. |
| 11 | "Papago 흐름에서 출발한 거다 — YouTube 보다가 모찌로 넘어가는 게 싫다" | **`ShowsSnippetView` (iOS 17+)** 발견 — Papago 가 실제로 쓰는 메커니즘. 외부 앱 컨텍스트 보존하면서 snippet UI 표시 가능. 큰 재설계 옵션. |

---

## 2. 현재 코드 상태 (작동 가능, 모달 흐름)

### 신규 / 변경된 파일

**코드 (iOS):**
- `mochi-ios/Targets/Cores/CorePersistence/Sources/AppGroup.swift` — `pendingBackTapDirectoryURL` 추가
- `mochi-ios/Targets/App/Sources/AppIntents/CaptureScreenshotIntent.swift` — `openAppWhenRun = true`, perform() 이 pending-backtap 디렉터리에 PNG stash 만
- `mochi-ios/Targets/App/Sources/AppIntents/QuickCaptureIntent.swift` — `.result(value:)` → `.result()` (crash fix)
- `mochi-ios/Targets/Cores/DesignSystem/Sources/ScreenshotScanAnimation.swift` — **NEW**, 얇은 빛 1.2초 위→아래 통과
- `mochi-ios/Targets/Features/FeatureCapture/Sources/BackTapModalFeature.swift` — **NEW** TCA reducer (phase: selecting/capturing/memo/savingMemo)
- `mochi-ios/Targets/Features/FeatureCapture/Sources/BackTapModalView.swift` — **NEW** SwiftUI, 풀스크린 모달
- `mochi-ios/Targets/App/Sources/RootFeature.swift` — BackTapModal presentation + pendingDiscovery 로직 + concurrent race 가드 + `.backTapModal(.dismiss)` 안전망
- `mochi-ios/Targets/App/Sources/RootView.swift` — `fullScreenCover` + `interactiveDismissDisabled(true)` + `onChange(of: scenePhase)`
- `mochi-ios/Targets/Cores/CorePersistence/Sources/InboundQueueConsumer.swift` — 코멘트 stale 정정 (`CaptureScreenshotIntent` 가 더 이상 inbound producer 아님)
- `mochi-ios/Project.swift` — `FeatureCapture` → `CoreNetworking` 의존 추가

**문서:**
- `docs/ARCHITECTURE.md` §1 토폴로지 + §2.3 캡처 진입 채널 표·노트 + §7 폴더 인덱스
- `docs/PRODUCT.md` §6.3 시나리오 C + §8.9 백탭 모달 사양
- `docs/DOMAIN_DESIGN.md` SQL 주석 (244-249) 의 백탭 흐름 설명
- `docs/PRIVACY_SENSITIVE_CAPTURE.md` §7.1 연동 지점에 `BackTapModalFeature` (미통합) 명시
- `docs/TODO.md` §3.0 백탭 단축어 가이드 + §3.4 에러 핸들링 보강 신설
- `docs/CHANGELOG.md` 2026-05-24 항목 (백탭 회귀 + codex 반영 두 줄)
- `mochi-ios/README.md` 입력 채널 표 + App Group 디렉터리 목록 + AppIntents 트리

**단축어 파일 (외부):**
- `/tmp/build_mochi_shortcut.py` — Python 빌더 (3-action plist 합성)
- `/tmp/mochi-backtap-capture.shortcut` — unsigned (1,170 bytes)
- `/tmp/mochi-backtap-capture-signed.shortcut` — `shortcuts sign --mode anyone` 처리 (21,964 bytes)

### 현재 흐름 (한 그림)

```
사용자 백탭 ┐
            │
[단축어] ───┤  스크린샷 → 이미지 변환(PNG, ASCII 파일명) → 모찌 화면 캡쳐 AppIntent
            │
            └─► CaptureScreenshotIntent.perform()
                  PNG → AppGroup/pending-backtap/<UUID>.png 에 stash
                  return .result()                            (openAppWhenRun = true)
                  └─► 모찌 앱 foreground 진입
                       └─► RootFeature.appBecameActive
                            └─► checkPendingBackTap
                                 └─► BackTapModalFeature 풀스크린 모달
                                      ├─ "캡쳐"  → 스캔 애니메이션 (1.2s) + commit (pending → captures + Realm + ingest)
                                      ├─ "메모"  → pending 폐기 + textarea → 저장
                                      └─ "취소"  → pending 폐기 + dismiss
```

---

## 3. 미해결 결정: snippet 흐름으로 갈 것인가? ⚠️

### 3.1 사용자 결정 대기 중인 옵션

**(A) Snippet 흐름 PoC 부터** — iOS 17 에서 `Button(intent:)` 가 snippet 안에서 안정 작동하는지 미니멀 데모로 검증 후 진행. **추천**.
**(B) Snippet 흐름 풀 구현 바로** — PoC 생략. 검증은 작업 끝난 뒤 한 번에.
**(C) 현재 모달 유지** — 베타 사용자 반응 데이터 기반 결정. 안전한 보수.

### 3.2 두 흐름 trade-off

| 항목 | 현재 (앱 모달, 작동 중) | Snippet (재설계 후보) |
|---|---|---|
| YouTube → 백탭 → 모찌 | 모찌 앱 떠올라옴 (YouTube 사라짐) | YouTube 위에 작은 카드. YouTube 계속 보임 |
| 캡쳐 시 컨텍스트 | ❌ 손실 | ✅ 보존 |
| 메모 시 컨텍스트 | ❌ 손실 | ❌ 손실 (어차피 키보드 필요) |
| UI 면적 | 풀스크린, 자유로운 디자인 | 시스템 카드 (Siri-like 영역), 작은 사이즈 |
| 캐릭터 + 스캔 애니메이션 | 큼, 임팩트 강함 | 작아짐, 시각 임팩트 ↓ |
| 디자인 자유도 | 100% (SwiftUI) | 시스템 컨테이너 안에서 — 제약 있음 |
| iOS 17 안정성 | 안전 (기본 fullScreenCover) | **검증 필요** — `Button(intent:)` interactivity 가 iOS 17 에서 안정 작동? |
| 인증 미완 처리 | LoginView 자연 진입 | snippet 안에서 "로그인 필요" 표시 + 앱 진입 유도 |
| 작업 분량 | 0 (이미 완료) | 약 현 작업의 50% (재설계) |

### 3.3 만약 snippet 으로 가기로 결정되면

**삭제 / 축소 대상:**
- `BackTapModalFeature.State.phase` 의 `.selecting` / `.capturing` 케이스 제거 → 메모 전용 (`.memo` / `.savingMemo` 만)
- `BackTapModalView` 의 `selecting` / `capturing` view 제거 → 메모 전용
- `RootFeature.checkPendingBackTap` 의 모달 띄우는 분기는 `OpenBackTapMemoIntent` 호출 시점에만

**신설 대상:**
- `Targets/App/Sources/AppIntents/BackTapSnippetView.swift` — SwiftUI snippet view (외부 앱 위 표시용)
- `Targets/App/Sources/AppIntents/CommitBackTapCaptureIntent.swift` — 캡쳐 분기, `openAppWhenRun = false`, `ShowsSnippetView`
- `Targets/App/Sources/AppIntents/OpenBackTapMemoIntent.swift` — 메모 분기, `openAppWhenRun = true` (textarea 필요)

**갱신 대상 (모든 변경에 CHANGELOG 한 줄 필수):**
- `CaptureScreenshotIntent.perform()` 반환 타입을 `some IntentResult & ShowsSnippetView` 로 변경. PNG stash 후 `.result(view: BackTapSnippetView(...))` 반환
- `Project.swift` — AppIntent 가 SwiftUI view 를 import 할 수 있는 의존성 그래프 확인 (DesignSystem 의 ScreenshotScanAnimation 사용 시)
- `docs/ARCHITECTURE.md` §1 토폴로지 + §2.3 채널 표/노트 (모달 → snippet)
- `docs/PRODUCT.md` §6.3 시나리오 C + §8.9 (풀스크린 모달 → snippet 카드)
- `docs/CHANGELOG.md` 2026-05-25 (또는 작업 일자) 항목

**예상 코드 sketch** — 자세한 패턴:

```swift
@available(iOS 17.0, *)
public struct CaptureScreenshotIntent: AppIntent {
    public static let openAppWhenRun = false           // ← 핵심
    @Parameter(title: "이미지", supportedTypeIdentifiers: ["public.image"])
    public var image: IntentFile

    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        let data = image.data
        guard data.count <= maxImageBytes else { throw .imageTooLarge(data.count) }
        let id = UUID()
        let url = AppGroup.pendingBackTapDirectoryURL
            .appendingPathComponent("\(id.uuidString).png")
        try data.write(to: url, options: [.atomic])
        return .result(view: BackTapSnippetView(pendingURL: url, captureID: id))
    }
}

struct BackTapSnippetView: View {
    let pendingURL: URL
    let captureID: UUID
    var body: some View {
        VStack(spacing: 12) {
            Text("이 화면을 어떻게 저장할까요?")
            HStack {
                Button(intent: CommitBackTapCaptureIntent(pendingURL: pendingURL, captureID: captureID)) {
                    Label("캡쳐", systemImage: "camera.viewfinder")
                }
                Button(intent: OpenBackTapMemoIntent(pendingURL: pendingURL, captureID: captureID)) {
                    Label("메모", systemImage: "square.and.pencil")
                }
            }
        }
    }
}
```

### 3.4 Snippet 흐름 채택 시 검증해야 할 것 (블로커 검증)

1. **iOS 17.x 실기에서 snippet 안의 `Button(intent:)` 가 작동하는가?** Apple Forum thread 783911 에 일부 렌더링 이슈 보고. 모찌 deployment target = 17.0 이라 critical.
2. **백탭으로 호출된 snippet 이 외부 앱 위에 실제로 표시되는가?** Siri/Spotlight 호출 시는 확정이지만 백탭(BackgroundShortcutRunner) 경로는 별도 검증.
3. **`URL` parameter 를 AppIntent 간 전달 가능한가?** `@Parameter var pendingURL: URL` 이 iOS 17 에서 지원되는지. 안 되면 path string 으로 우회.
4. **시스템 snippet 카드의 최대 면적**, 모찌 캐릭터 + 두 버튼 + 안내 텍스트가 들어가는가?

검증 1번이 실패하면 → iOS 18+ 한정 또는 폴백 전략 (iOS 17 은 모달, iOS 18+ 는 snippet). 작업 분량 ↑.

---

## 4. 코드 완성도 / 정합성 기준 — 절대 깨지면 안 되는 invariant

### 4.1 CLAUDE.md 원칙 준수
- **§1 Think Before Coding**: 가정 명시 + 모호하면 묻기. 본 작업 진행 전 사용자 컨펌 필수.
- **§2 Simplicity First**: 불필요한 추상화 금지. 200줄로 줄일 수 있으면 줄임. "시니어가 보면 과설계라 할까?" 자문.
- **§3 Surgical Changes**: 주변 코드 "개선" 금지. 본인 변경이 만든 고아만 정리. 변경된 모든 줄이 사용자 요청까지 직접 추적 가능해야 함.
- **§4 Goal-Driven Execution**: "검증 방법" 을 단계마다 명시.
- **§6 변경 기록 규칙 (필수)**: 의미 있는 변경마다 (1) 해당 docs 동기화 + (2) `docs/CHANGELOG.md` 맨 위 한 줄. 두 단계는 작업의 일부. 누락은 미완성.

### 4.2 도메인 invariant (`docs/DOMAIN_DESIGN.md`)
- `Capture.id == CaptureSource.id` — 단일 UUID 만으로 식별. Realm primary key + 백엔드 capture id + idempotency key derivation 의 base.
- 백탭 캡쳐는 channel = `.screenshot` (변경 금지).
- 4-Intent 상태 머신 (`LifecyclePolicy`) 강제 — 위반 시 `LifecycleTransitionError`.

### 4.3 백탭 모달 invariant (`docs/ARCHITECTURE.md` §2.3)
- pending PNG 는 정상 분기 (캡쳐/메모/취소) 에서 자식 reducer 가 폐기 보장.
- 비정상 종료 (force-quit / crash) 후 잔재는 다음 launch 의 `checkPendingBackTap` 이 가장 최근 1장 promote + 나머지 stale 폐기.
- concurrent discovery: 활성 모달의 pending URL 과 같은 URL 은 절대 폐기 금지 (race fix).

### 4.4 doc-code 정합성
- 어떤 코드 변경도 docs 와 어긋난 채로 끝내지 않음. 동기화 불가하면 사용자에게 보고하고 멈춤.
- README / TODO / DOMAIN_DESIGN / ARCHITECTURE / PRODUCT / PRIVACY 6개 문서가 모두 같은 사실을 말해야 함.
- 표현 정확도 (특히 retry 강도) — 과장 금지. "auto retry" 같은 모호 표현 대신 "1회 추가 시도 후 `.syncFailed` marking, 자동 retry 종료" 처럼 정확하게.

### 4.5 에러 핸들링 기준
- 사용자 직접 입력 (메모 textarea) 손실 가능성 → 베타에서 1건이라도 보고 시 즉시 보강.
- Pre-upsert (File IO / Realm) 실패는 silent dismiss 허용 (`docs/TODO.md` §3.4 에 명시) — 디스크 풀 같은 극단 상황만, 진짜 fix 는 ErrorReporter 인프라 동반.
- Network ingest 실패는 `.pendingUpload` 로 Realm 에 남아 1회 추가 retry — fallback 의 정확한 강도.

### 4.6 codex 리뷰 통과 기준
- must-fix 0 개 (모두 반영했음을 검증).
- SHOULD-CONSIDER 항목은 docs/TODO 로 분리하되 *이유* 명시.
- nit 은 무료 fix 가능하면 처리.

---

## 5. 검증 체크리스트 (사용자가 실기 검증해야 할 것)

### 5.1 현재 모달 흐름 검증
```bash
cd /Users/jun/dev/mochi/mochi-ios
tuist generate
# Xcode → Clean Build Folder (⇧⌘K) → Run on device
```

- [ ] 빌드 통과 (FeatureCapture → CoreNetworking 의존 정상)
- [ ] 단축어 import: `/tmp/mochi-backtap-capture-signed.shortcut` 을 AirDrop 으로 본인 iPhone 에 전송 → Shortcuts 앱이 열리고 단축어 추가
- [ ] 로그인 → 단축어 직접 실행 (▶) → 풀스크린 모달 등장
- [ ] "캡쳐" 탭 → 1.2초 스캔 애니메이션 → dismiss → Inbox 에 새 항목
- [ ] "메모" 탭 → textarea → 저장 → dismiss → Inbox 에 텍스트 캡쳐
- [ ] "취소" 탭 → dismiss → Inbox 변화 없음
- [ ] 백탭 더블탭 → 동일 흐름
- [ ] **invariant 검증**: 각 분기 후 App Group 의 `pending-backtap/` 디렉터리가 비어 있는지 (Settings → Apps → Mochi → Files 또는 `xcrun simctl spawn ... ls` 로 확인)

### 5.2 미인증 상태 처리 검증
- [ ] 로그아웃 → 단축어 실행 → 앱이 LoginView 로 떠올라옴, 모달 X, pending 보존
- [ ] 로그인 → 자동으로 모달 등장
- [ ] (DEBUG 빌드) OnboardingView 떠 있는 상태에서 단축어 실행 → 모달 X (RootView 미진입). 온보딩 완료 후 모달 등장하는지 확인

### 5.3 비정상 종료 처리 검증
- [ ] 모달 떠 있는 상태에서 모찌 앱 force-quit → 다음 launch → pending 복구되어 모달 다시 등장
- [ ] pending-backtap 디렉터리에 stale 파일 여러 개 있는 상태 → launch → 가장 최근만 promote, 나머지 폐기

### 5.4 sandbox extension 우회 검증
- [ ] 디바이스 언어 한국어 유지 + 단축어 실행 → `_INIssueSandboxExtensionWithTokenGeneratorBlock` 에러 없이 작동 (이미지 변환 액션이 ASCII 파일명 부여)

---

## 6. 미수정 항목 (의도적으로 docs/TODO 로 분리한 것)

각각의 분리 사유는 이미 대화에서 사용자에게 설명함. 요약:

### A. `BackTapModalFeature.commitScreenshot` 실패 분기 미세분 (`BackTapModalFeature.swift:92`)
- **분리 사유**: pre-upsert (File IO / Realm) 실패는 디스크 풀 같은 극단 상황만 발생. 진짜 fix 는 alert UI + ErrorReporter 인프라 동반 — MVP scope 밖.
- **언제 수정**: production 직전. ErrorReporter (sentry/firebase) 도입 후.
- **기록 위치**: `docs/TODO.md` §3.4

### B. `BackTapModalFeature.commitMemo` 실패 UI state (`BackTapModalFeature.swift:135`)
- **분리 사유**: Realm upsert 실패 시 사용자 입력 텍스트가 silent dismiss 와 함께 사라짐. 손실 강도가 캡쳐보다 큼 (회복 불가). 그러나 발생 빈도가 매우 낮고, 진짜 fix 는 phase 복귀 + alert + memoText 보존 + retry — 추가 UI 인프라.
- **언제 수정**: 베타 테스트에서 "메모 사라짐" 보고 1건이라도 발생 시 즉시.
- **기록 위치**: `docs/TODO.md` §3.4

### C. `CaptureSyncWorker` `.syncFailed` retry 부재 (`CaptureSyncWorker.swift:61`)
- **분리 사유**: 현재 `.pendingUpload` 만 retry. 한 번 실패 후 `.syncFailed` 로 marking 되면 자동 재시도 없음. docs 의 "fallback" 표현이 과장이라 정확화 처리. 진짜 retry policy 변경은 별도 결정 (backoff 정책 + Inbox retry UI).
- **언제 수정**: Inbox 에 retry 버튼 UI 추가하는 시점에 함께.
- **기록 위치**: `docs/TODO.md` §3.4

### D. Force-quit 후 모달 invariant
- **분리 사유**: codex 가 우려했으나 실제로는 invariant 표현 문제. 정상 분기에서 폐기 + 비정상 종료 잔재는 다음 launch 의 `checkPendingBackTap` 이 정리. 표현 정확화로 해결.
- **수정 완료**: `docs/ARCHITECTURE.md` §2.3 표현 갱신.

### E. 미인증 상태 UX 보강 (옵션)
- **분리 사유**: LoginView 에 "백탭한 캡쳐 1건 대기 중" 배너 표시는 nice-to-have. 현재는 pending 보존 + 로그인 후 자동 모달로 충분.
- **언제 수정**: 베타 사용자 인지율 데이터 확보 후. UX 작업.
- **기록 위치**: 아직 TODO 항목 없음. 필요 시 추가.

---

## 7. 알려진 위험 / 경고

### 7.1 단축어 파일이 `/tmp/` 에 있음
- `/tmp/build_mochi_shortcut.py` + `/tmp/mochi-backtap-capture-signed.shortcut`
- macOS 재부팅 시 사라질 수 있음.
- **권장 액션**: 작동 확정 후 `mochi-ios/scripts/build-backtap-shortcut.py` 등으로 영구 이동 + CHANGELOG.

### 7.2 SourceKit lint 노이즈 (무시 가능)
- Project.swift 변경 후 `tuist generate` 안 한 상태에서는 SourceKit 이 "No such module 'ComposableArchitecture'" 등을 띄움. 빌드는 정상. `tuist generate` 후 사라짐.

### 7.3 단축어 액션 identifier 가정
- `WFWorkflowActionIdentifier = "com.IndexFinger.mochi.CaptureScreenshotIntent"` — Apple 비공개 포맷. iOS 마이너 업데이트로 깨질 위험 있음.
- **권장**: iOS 메이저 업데이트마다 단축어 정상 동작 검증.

### 7.4 PRIVACY_SENSITIVE_CAPTURE 통합 미완
- `docs/PRIVACY_SENSITIVE_CAPTURE.md` §7.1 에 `BackTapModalFeature` 가 "계획 — 현재 미통합" 으로 명시되어 있음.
- MVP §8 구현 순서대로 진행 시 통합. 단순 명시 정확성만 보장.

---

## 8. 다음 세션이 가장 먼저 할 일

### 만약 사용자가 옵션 A (Snippet PoC 부터) 선택
1. `_workspace/2026-05-24-backtap-flow-handoff.md` (이 문서) 읽고 컨텍스트 회복
2. iOS 17.x 실기 또는 시뮬레이터에서 미니멀 SnippetIntent PoC 작성:
   - 입력: 정적 텍스트 + Button(intent:label:) 2개
   - 검증: 백탭 + 단축어 실행 시 외부 앱 위에 카드 표시 되는가, 버튼 탭 시 다른 intent 작동하는가
3. 결과를 사용자에게 보고 → 풀 구현 진행 여부 결정

### 만약 사용자가 옵션 B (Snippet 풀 구현 직진) 선택
1. `_workspace/2026-05-24-backtap-flow-handoff.md` §3.3 sketch 따라 작업
2. 신설 3 파일 + `CaptureScreenshotIntent` 수정 + `BackTapModalFeature` 축소
3. 문서 5개 갱신 + CHANGELOG 한 줄
4. 빌드 → 실기 검증 → codex 리뷰 → must-fix 반영

### 만약 사용자가 옵션 C (현재 유지) 선택
1. 본 문서를 archive 로 표시 (예: `_workspace/archived/`)
2. `docs/TODO.md` §3.4 의 production 직전 항목들이 다음 작업 대상

### 만약 사용자가 다른 결정 (옵션 D, snippet 도 보류 + 현재 모달 유지 + 다른 surface 추가 등)
- 새 handoff 작성 후 진행.

---

## 9. 참고 자료

### Apple Docs (snippet 흐름 검토용)
- [ShowsSnippetView](https://developer.apple.com/documentation/appintents/showssnippetview)
- [openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun)
- [Displaying static and interactive snippets](https://developer.apple.com/documentation/AppIntents/displaying-static-and-interactive-snippets)
- [Accelerating app interactions with App Intents](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents/)

### 외부 분석
- [Exploring interactive snippet intents — Nutrient](https://www.nutrient.io/blog/wwdc25-snippet-intents/)
- [App Intents Interactive Snippets in iOS 26 — Superwall](https://superwall.com/blog/app-intents-interactive-snippets-in-ios-26/)
- [Create an Interactive Snippet Shortcut using App Intents — Swiftjective-C](https://www.swiftjectivec.com/create-interactive-snippet-shortcut-in-appintents/)

### Apple Forum (validation)
- [thread/783911 — View shown by App Intent with ShowsSnippetView doesn't render](https://developer.apple.com/forums/thread/783911) — iOS 17 렌더링 이슈 보고. 검증 필수.
- [thread/759160 — AppIntents don't show up in Shortcuts](https://developer.apple.com/forums/thread/759160) — AppShortcutsProvider 가 메인 App 타겟에 있어야 한다는 결정의 근거.

### 내부 문서 우선 참조 순서
1. `CLAUDE.md` — 모찌 협업 원칙 (§1-§6)
2. `docs/ARCHITECTURE.md` §2.3 — 캡처 진입 채널 (정합성 기준)
3. `docs/CHANGELOG.md` 2026-05-24 — 본 작업 회귀의 사유와 변경 범위
4. `docs/PRODUCT.md` §6.3 / §8.9 — 백탭 기획 의도 (silent 가 아닌 모달 흐름)
5. `docs/TODO.md` §3.0 / §3.4 — 단축어 가이드 + 에러 핸들링 보강

---

## 11. `.shortcut` 파일 제작 가이드 (재생성 / 확장 시 필독)

### 11.1 왜 plist 직접 합성하는가

Mac Shortcuts.app 으로 export 하는 방법도 있지만 코드 합성 채택 이유:
- **재현 가능성**: 빌더 스크립트가 있으면 누구든 같은 산출물 생성
- **버전 관리**: Python plist 가 git 으로 diff 가능
- **AppIntent 시그니처 변경 시 자동 재생성**: 한 줄 수정 → 재빌드

다만 **Mac Shortcuts.app 의 수동 단축어를 baseline 으로 보관**할 것 (§11.11).

### 11.2 plist 구조 핵심

```python
{
    "WFWorkflowName": "모찌 백탭 캡쳐",
    "WFWorkflowClientVersion": "2607.1.3",            # Shortcuts.app build (호환성 시그널)
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": { ... },                        # 시각 식별만, 동작 영향 X
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": [],                            # NCWidget / WatchKit 등 노출 위치
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowHasShortcutInputVariables": False,
    "WFQuickActionSurfaces": [],
    "WFWorkflowActions": [...]                        # ★ 핵심: 액션 배열
}
```

`plistlib.dump(shortcut, f, fmt=plistlib.FMT_BINARY)` — **binary plist** 로 저장 (XML 도 가능하지만 iOS 가 binary 기대).

### 11.3 액션 identifier 형식

| 종류 | 형식 | 예시 |
|---|---|---|
| 시스템 액션 (Apple 내장) | `is.workflow.actions.<name>` | `is.workflow.actions.takescreenshot`, `is.workflow.actions.image.convert` |
| 제3자 앱 AppIntent | `<bundle-id>.<IntentTypeName>` | `com.IndexFinger.mochi.CaptureScreenshotIntent` |

AppIntent identifier 검증법:
```bash
# 빌드된 .app 의 Metadata.appintents 에서 fullyQualifiedTypeName 확인
strings ~/Library/Developer/Xcode/DerivedData/Mochi-*/Build/Products/Debug-iphoneos/Mochi.app/Metadata.appintents/extract.actionsdata \
    | grep fullyQualifiedTypeName
# → "Mochi.CaptureScreenshotIntent" — 점 뒤가 IntentTypeName
```

→ identifier = `<bundleIdPrefix>.<IntentTypeName>` = `com.IndexFinger.mochi.CaptureScreenshotIntent`

### 11.4 액션 간 출력→입력 연결 (UUID)

각 액션이 자기 UUID 를 가지고, 다음 액션의 parameter 가 그 UUID 를 참조:

```python
SCREENSHOT_UUID = str(uuid.uuid4()).upper()

# 액션 1: 출력 생성
{
    "WFWorkflowActionIdentifier": "is.workflow.actions.takescreenshot",
    "WFWorkflowActionParameters": {
        "UUID": SCREENSHOT_UUID,
        "WFTakeScreenshotMainScreenOnly": True,
    }
},
# 액션 2: 액션 1의 출력을 입력으로 받음
{
    "WFWorkflowActionIdentifier": "is.workflow.actions.image.convert",
    "WFWorkflowActionParameters": {
        "WFInput": {
            "Value": {
                "Type": "ActionOutput",
                "OutputName": "스크린샷",            # 액션 1 출력의 시스템 이름
                "OutputUUID": SCREENSHOT_UUID,       # ★ 액션 1 UUID 참조
            },
            "WFSerializationType": "WFTextTokenAttachment",
        },
        "WFImageFormat": "PNG",
    },
}
```

### 11.5 이미지 변환(PNG) 액션 — 왜 필수인가

한국어 locale iPhone 에서 "스크린샷 찍기" 출력의 파일명이 `이미지.png` (한국어 "이미지"). WorkflowKit `BackgroundShortcutRunner` 가 이 한국어 path 에 대해 sandbox read extension 발급 실패 → `_INIssueSandboxExtensionWithTokenGeneratorBlock Could not create sandbox read extension ... Operation not permitted` fatal. 결과적으로 AppIntent 의 `image.data` 접근 실패.

이미지 변환 액션이 ASCII 임시 파일명으로 재인코딩 → sandbox extension 발급 통과.

→ **모찌 백탭 단축어는 반드시 3-액션 구성 (스크린샷 → 이미지 변환 → AppIntent)**. 2-액션으로 줄이려는 시도는 한국어 locale 사용자에게 깨짐.

### 11.6 서명 (외부 import 의 필수 조건)

iOS 15+ 는 unsigned `.shortcut` 의 외부 import (AirDrop/메일/iMessage/HTTPS deep link) 를 차단함 — "서명되지 않은 단축어 파일을 가져오는 동작은 지원하지 않습니다" 에러. macOS `shortcuts` CLI 로 서명:

```bash
shortcuts sign --mode anyone \
    --input  /tmp/mochi-backtap-capture.shortcut \
    --output /tmp/mochi-backtap-capture-signed.shortcut
```

| `--mode` | 의미 |
|---|---|
| `anyone` | 누구나 import 가능. **모찌 배포용 채택** |
| `people-who-know-me` | AirDrop/iMessage 등 contact 한정 (기본값) |

서명 후 파일 크기: 약 1 KB → 22 KB (Apple-signed archive blob).

### 11.7 배포 경로

| 방식 | 대상 | 비고 |
|---|---|---|
| **AirDrop** | 개발자 본인 디바이스 | 빠른 테스트. `open <file>` 로 Finder 열기 → 본인 iPhone 선택 |
| **iCloud share link** | 사용자 배포 (권장) | iPhone Shortcuts 앱에서 단축어 export → 길게 누름 → 공유 → "iCloud 링크 복사". Apple 인프라가 서명 처리, untrusted 옵션 불필요 |
| **HTTPS 호스팅 + deep link** | 인앱 자동 추가 | `.shortcut` 파일을 GCS/Cloudflare 에 두고 `shortcuts://import-shortcut?url=<https>&name=<name>` deep link. `&silent=true` 는 iOS 15 이후 차단되어 항상 미리보기 노출 |

### 11.8 단축어 재생성이 필요한 시점

다음 중 하나라도 발생하면 빌더 재실행 + 재서명 + 재배포:

| 변경 | 재생성 필요? |
|---|---|
| AppIntent 의 `title` / `description` / `openAppWhenRun` 등 static 값 | ❌ (대부분 불필요. AppShortcuts metadata 만 갱신) |
| AppIntent struct **이름** 변경 (`CaptureScreenshotIntent` → `BackTapCaptureIntent`) | ✅ **필요** — identifier 가 바뀜 |
| AppIntent 의 `@Parameter` 추가 / 제거 / 타입 변경 | ✅ **필요** |
| `bundleIdPrefix` 변경 | ✅ **필요** |
| 단축어 액션 wiring 변경 (예: 이미지 변환 추가/제거) | ✅ **필요** |
| ScreenshotScanAnimation 같은 모찌 내부 view 변경 | ❌ 불필요 (단축어와 무관) |

재생성 절차:
```bash
python3 /tmp/build_mochi_shortcut.py
shortcuts sign --mode anyone \
    --input  /tmp/mochi-backtap-capture.shortcut \
    --output /tmp/mochi-backtap-capture-signed.shortcut
# AirDrop 또는 새 iCloud link 발급
```

### 11.9 흔한 함정

| 함정 | 증상 | 해결 |
|---|---|---|
| unsigned 파일을 직접 import | "서명되지 않은 단축어 파일을 가져오는 동작은 지원하지 않습니다" | `shortcuts sign --mode anyone` 필수 |
| AppIntent identifier 추측 틀림 | import 는 되지만 액션 1개가 "알 수 없는 동작" 으로 표시 (빨간 경고) | `Metadata.appintents/extract.actionsdata` 에서 `fullyQualifiedTypeName` 확인 |
| AppIntent 가 메인 App 타겟 외부 | 단축어 앱 검색에 모찌 아예 안 나옴 | App 타겟 내부 (`Targets/App/Sources/AppIntents/`) 위치. Apple Forum thread 759160 |
| `Metadata.appintents` 누락 | AppShortcutsProvider 자동 등록 안 됨 | `find ~/Library/Developer/Xcode/DerivedData -name "Metadata.appintents"` — 결과 없으면 Clean Build Folder + 재빌드 |
| `.result(value:)` + `some IntentResult` | 단축어 실행 시 모찌 fatal crash ("Did not declare ReturnsValue but provided one") | `.result()` 또는 반환 타입에 `& ReturnsValue<T>` 추가 |
| 한국어 파일명 (`이미지.png`) | `_INIssueSandboxExtensionWithTokenGeneratorBlock Operation not permitted` | 단축어에 "이미지 변환(PNG)" 액션 끼움 (ASCII 파일명 부여) |
| iOS 마이너 업데이트 후 액션 식별자 변경 | 기존 작동하던 단축어가 새 OS 에서 깨짐 | Apple 비공개 포맷 — 메이저 업데이트마다 회귀 테스트 |

### 11.10 테스트 도구

```bash
# unsigned .shortcut 의 plist dump (구조 확인)
plutil -p /tmp/mochi-backtap-capture.shortcut

# signed 파일은 Apple-archive 라 plutil 안 통함. file 로 타입만:
file /tmp/mochi-backtap-capture-signed.shortcut
# → "data" → 정상 (signed archive 라 plist 가 아님)

# macOS 의 단축어 목록 (디바이스가 iCloud 로 sync 되어 있어야)
shortcuts list

# 디바이스에서 단축어 직접 실행 (이름으로)
shortcuts run "모찌 백탭 캡쳐"

# Mac Shortcuts.app 에서 만든 단축어를 reference 로 export:
# Shortcuts.app → 단축어 선택 → File → Export → As File... → .shortcut 저장
# 그 파일을 plutil -p 로 dump → 본인 빌더 스크립트와 비교
```

### 11.11 Mac Shortcuts.app baseline 보관 (권장)

코드 합성 단축어와 별개로, **Mac Shortcuts.app 에 동일 단축어를 수동으로 만들어 보관**:

1. PoC / 새 AppIntent 추가 시 reference (Apple 의 정확한 액션 식별자 / parameter 형식 확인)
2. 단축어 포맷이 iOS 업데이트로 깨졌을 때 baseline
3. iCloud share link 발급 시 그 단축어를 직접 공유

이 baseline 단축어를 `plutil -p` 로 dump 한 결과를 `mochi-ios/scripts/reference-backtap.plist.txt` 같은 곳에 텍스트로 commit 해두면, 향후 빌더 스크립트와 diff 가능.

### 11.12 빌더 스크립트 영구 이전 권장 위치

현재 `/tmp/build_mochi_shortcut.py` 에 있어 macOS 재부팅 시 사라짐.

**권장 이전 경로**: `mochi-ios/scripts/build-backtap-shortcut.py`

이전 시 동반 작업:
- [ ] `mochi-ios/scripts/README.md` 신설 — §11.3 의 identifier 검증법, §11.6 서명 명령, §11.8 재생성 시점 포함
- [ ] `mochi-ios/.gitignore` 의 `.shortcut` 파일 추적 정책 결정 (signed 는 commit / unsigned 는 ignore 권장 — signed 가 22KB 라 부담 적음)
- [ ] `docs/TODO.md` §3.0 의 "단축어 자체는 코드가 아니므로" 표현 정정 — 이제 빌더 스크립트가 코드로 있음
- [ ] `docs/CHANGELOG.md` 한 줄

---

## 12. 인수인계 도장

- 작성: 2026-05-24
- 작성자: Claude (Sonnet/Opus 4.7)
- 마지막 사용자 메시지: snippet 흐름 옵션 A/B/C 결정 요청 + 본 handoff 작성 요청
- 현재 git: 미초기화 (`Is a git repository: false`). 변경은 모두 working tree 에만.
- 빌드: 미실행 (사용자가 `tuist generate` + Xcode 빌드 미수행).
- 실기 검증: 미수행.

**다음 세션 시작 시 본 문서 §1 → §3 → §8 순으로 읽으면 컨텍스트 100% 회복.**
**단축어 파일을 재생성·확장할 일이 생기면 §11 만 정독하면 자력으로 가능.**
