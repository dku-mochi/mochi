---
level: 2
mode: reference
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: iOS 클라이언트 진입점·빌드 가이드·모듈 구조. iOS 코드를 처음 보거나 Tuist generate/test/빌드 명령이 필요할 때 읽어라. App Group, Cores/Features/App 레이어 규칙, App Intents 배치, swift-openapi-runtime 의존성 포함.
---

# 모찌 iOS (mochi-ios)

> Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트 — iOS 클라이언트

2026 SW중심대학 디지털 경진대회 SW부문 출품작 / 팀 **세얼간이**

## 기술 스택

| 분류 | 기술 | 비고 |
| --- | --- | --- |
| 언어 | Swift 5.10 | strict concurrency = complete |
| UI | **SwiftUI + The Composable Architecture (TCA) 1.x** | Combine 기반 effect, TestStore |
| 최소 타겟 | iOS 17.0 | App Intents, EventKit fullAccess, Observable 매크로 |
| 프로젝트 도구 | Tuist 4.x | Project.swift 단일 파일 + 다중 framework target |
| 시스템 연동 | EventKit · EventKitUI · App Intents · ShareExtension | |
| 로컬 DB | Realm | App Group 공유 컨테이너에 단일 파일 |
| 네트워킹 | swift-openapi-runtime + URLSession | 백엔드 OpenAPI(`/api/v1`) → swift-openapi-generator |
| AI 백엔드 | mochi-backend (FastAPI + Gemini 3.5 Flash) | SSE 스트림 + REST |
| 이미지 캐싱 | Kingfisher | |
| 디자인 시스템 | DesignSystem 모듈 자체 토큰 (코드 기반) | dynamic color, no Bundle |

## 모듈 구조 (Hexagonal · Feature-Modular)

```
mochi-ios/
├── Project.swift              Tuist 정의 (모든 target)
├── Tuist.swift                config
├── Tuist/Package.swift        SPM 의존성
└── Targets/
    ├── App/                   메인 앱 셸 + @main
    │   ├── Sources/
    │   │   ├── MochiApp.swift, RootFeature.swift, RootView.swift, AppDependencies.swift, ...
    │   │   └── AppIntents/    QuickCaptureIntent (텍스트/URL · Siri/Spotlight) + CaptureScreenshotIntent (이미지 · 백탭 단축어가 PNG stash + snippet 카드 표시, `openAppWhenRun = false`) + BackTapSnippetView (외부 앱 위 시스템 카드 SwiftUI view) + CommitBackTapCaptureIntent (snippet 캡쳐 분기 background commit) + OpenBackTapMemoIntent (snippet 메모 분기 → 모찌 foreground 진입) + MochiShortcuts (AppShortcutsProvider)
    │   ├── Resources/Assets.xcassets
    │   └── Support/Info.plist, App.entitlements
    ├── Cores/
    │   ├── CoreDomain/        도메인 모델 (Intent, Capture, AgentRun, LifecyclePolicy ...)
    │   ├── CorePersistence/   Realm + App Group + CaptureRepository protocol
    │   ├── CoreNetworking/    MochiAPIClient, APIErrorEnvelope (OpenAPI 어댑터)
    │   ├── CoreAgentClient/   AgentStreamClient (SSE/WebSocket)
    │   ├── CoreIntegrations/  CalendarSyncing (EventKit/Reminders)
    │   └── DesignSystem/      MochiTheme, IntentBadge, ...
    ├── Features/
    │   ├── FeatureInbox/      받은 기록 목록 (필터 + 라우팅)
    │   ├── FeatureCapture/    Agent loop stream UI
    │   ├── FeatureSearch/     자연어 질의
    │   ├── FeatureDetail/     상세 + 캘린더/리마인더 sync
    │   └── FeatureSettings/   서버 endpoint, 자동 동기화 토글
    └── ShareExtension/        NSExtensionPrincipalClass (스토리보드 X)
```

> AppIntents 는 **별도 extension 타겟이 아니라 App 타겟 내부** 에 있다. `AppShortcutsProvider` 와 그것이 참조하는 `AppIntent` 는 메인 App 타겟에 위치해야 시스템이 인덱싱하기 때문 (Apple Developer Forums thread 759160).

각 모듈은 다음 의존 규칙을 지킨다:

```
App  ───────► Features ───────► Cores (Domain / Persistence / Networking / AgentClient / Integrations / DesignSystem)
                  └───► DesignSystem
Features는 서로 직접 의존하지 않는다 (RootFeature가 조합만 담당).
```

## App Group 공유

App, ShareExtension 두 타겟이 동일 App Group `group.com.IndexFinger.mochi` 에 속한다. AppIntents 는 App 타겟 내부이므로 App 의 entitlement 를 그대로 쓴다.
- 공유 Realm: `<container>/mochi.realm`
- Inbound 큐(ShareExtension·`QuickCaptureIntent` 진입 → 메인 앱): `<container>/inbound-queue/*.json`
- Pending Back-Tap (snippet 흐름 단명 stash): `<container>/pending-backtap/<captureID>.png` (단축어가 stash, snippet 분기 commit 시 폐기) + `<container>/pending-backtap/<captureID>.memo` (메모 분기 marker, 모달 종료 시 폐기)
- 캡처 이미지: `<container>/captures/...`

## 시작하기

### 사전 준비
```bash
brew install tuist swiftlint
```

### 프로젝트 생성 및 실행
```bash
tuist install
tuist generate
open Mochi.xcworkspace
```

### 테스트
```bash
tuist test
```

## 핵심 도메인 — 4 Intent

`CoreDomain.LifecyclePolicy` 가 Intent별 상태 머신을 강제한다.

| Intent | 자동 동작 | 합법 전이 |
| --- | --- | --- |
| **schedule** | EventKit/Google Calendar sync | `ingested → analyzing → active → archived(scheduleEnded)` |
| **todo** | Reminders sync | `ingested → analyzing → active → archived(todoCompleted)` |
| **knowledge** | RAG 인덱싱 | `active → decaying → reviewRequested → archived(knowledgeStale)` (또는 → active 복귀) |
| **memo** | 영구 보관 | `active → archived(userManual)` |

위반 시 `LifecycleTransitionError.illegalTransition` 발생 — `LifecyclePolicyTests` 가 invariant를 보장한다.

## 입력 채널

| 채널 | 진입점 | 모듈 / 위치 |
| --- | --- | --- |
| 외부 공유 시트 (의식적 캡처) | `ShareExtensionPrincipal` → `ShareEntryView` 메모/확인 모달 → inbound 큐 적재 | `ShareExtension` 타겟 |
| 백탭 (snippet 카드) | 사용자 단축어 → `Take Screenshot` → 이미지 변환(PNG) → `CaptureScreenshotIntent` (`openAppWhenRun = false`) → `pending-backtap/<captureID>.png` stash + `BackTapSnippetView` 가 외부 앱 위에 카드 표시. "캡쳐" 선택 시 `CommitBackTapCaptureIntent` 가 background commit (모찌 앱 안 깸). "메모" 선택 시 `OpenBackTapMemoIntent` 가 `.memo` marker stash + 모찌 foreground → `BackTapModalFeature` 풀스크린 모달 (textarea) | App 타겟 `App/Sources/AppIntents/` + `FeatureCapture/BackTapModalFeature` |
| Siri / Spotlight (텍스트 메모) | `QuickCaptureIntent` + `MochiShortcuts` (모찌 UI 우회, inbound 큐 직접 적재) | App 타겟 `App/Sources/AppIntents/` |
| 앱 내 직접 입력 | `CaptureFeature` (TCA) | `FeatureCapture` |

세 외부 surface 는 의도에 따라 분리되어 있다 (공유시트=의식적·메모 입력 / 백탭=외부 앱 컨텍스트 보존 snippet + 분기 선택 / 음성검색=텍스트). 출력 경로도 다르다 — 공유시트·Siri 는 동일한 `InboundCapturePayload` JSON 큐를 거치고, 백탭은 snippet 분기에 따라 Realm `Capture` 를 직접 upsert (큐 우회). surface 분리 근거는 [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §2.3 노트.

## 백엔드 계약

`CoreNetworking.MochiAPIClient` 프로토콜이 백엔드 `/api/v1` 와의 단일 계약이다.
실제 구현은 백엔드의 OpenAPI 스펙(`mochi-backend/openapi.json`, `make openapi` 로 생성)에서 swift-openapi-generator로 자동 생성된 클라이언트를 주입한다.

모든 요청은:
- `X-Mochi-Request-ID` 헤더로 trace 가능
- `Idempotency-Key` 로 중복 등록 방지
- 에러 응답은 `APIErrorEnvelope` 통일 포맷

## 참고

- iOS UI 스택 결정: SwiftUI + TCA (greenfield · state-heavy · extension-heavy · 2026 Apple 투자 방향과 정렬)
- 베이스 패턴 일부는 [지금알바 iOS](../../work/nowalba/our-school-ios/our-school-app) 의 Tuist 멀티 타겟 구조를 참고
