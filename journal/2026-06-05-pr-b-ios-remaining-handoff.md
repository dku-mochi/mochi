---
level: 3
mode: log
status: active
last_verified: 2026-06-05
confidence: 0.8
owners: [송준서]
title: PR-B iOS 잔여(B6·B6½·B7) handoff — LA 재배선·SSE·알림
description: PR-B 백엔드·iOS B5 완료 후 iOS 잔여 구현 인수인계. LA content-state 계약 통일·Mock→Mochi 리네임·전채널 LA·NotificationContent 삭제·SSE live·알림 핸들러. Live Activity·AgentStreamClient·MochiItemSyncWorker·NotificationContent 손대기 전 읽어라.
---

# PR-B iOS 잔여 handoff — B6(LA 재배선)·B6½(SSE)·B7(알림)

> 백엔드 PR-B + iOS B5 는 **완료·커밋**됐다. 이 문서는 iOS 잔여(B6/B6½/B7)를 다음 세션이
> 바로 착수하게 쓴 인수인계다. 전체 설계 단일원천은 `2026-06-05-pr-b-live-activity-apns-handoff.md`,
> 본 문서는 그 위에 **iOS 잔여 코드 현황 + content-state 통일 설계 + 단계별 구현**을 더한다.

---

## 0. 현재 상태 (2026-06-05)

| 단계 | 상태 |
|---|---|
| 백엔드 B0~B-SSE | ✅ **커밋 `8aa0b31`** (review_options 영속·notifications 모듈·outbox push 훅·SSE 재작성). codex review P1 3건+P2 수정 완료 |
| iOS B5 (APNs 토큰 등록) | ✅ **커밋 `a77ac62`** — AppDelegate·push-token op(generate.sh)·entitlement. **미검증**(샌드박스 xcodebuild `DVTBuildVersion` 제약 — tuist build/test 는 사용자 환경 필요). **codex 리뷰 미실시** → 다음 세션 tuist 검증 후 함께 |
| **B6 LA 재배선** | ⏸️ 착수 전 |
| **B6½ SSE live** | ⏸️ 착수 전 |
| **B7 알림 핸들러** | ⏸️ 착수 전 |

브랜치: `feat/be-live-activity-apns` (develop 분기, PR-A #9 미머지 — ShareExt 영역이라 무관).

---

## 1. ⚠️ 핵심 발견 — LA content-state 계약 통일 (B6 의 숨은 핵심)

백엔드 LA push(B4, `notifications/application/send_notification.py` `_build_live_activity`)가 보내는
`aps.content-state` 와 iOS `ContentState` 가 **구조가 다르다.** LA push 가 iOS ContentState 를
시스템이 자동 decode·갱신하므로 **키가 정확히 일치해야** background LA 갱신이 동작한다.

- **백엔드가 보내는 content-state** (정본): `{"phase":"ready", "needsReview":bool, "summary":str, "candidates":[{"intentType":str, "label":str, "reasoning":str}]}`
- **현재 iOS** `MockUseCaseActivityAttributes.ContentState`: `{phase, candidates:[{label,intent,applicability}], selectedLabel}`

`applicability`(점수)는 2026-06-04 빅뱅으로 **폐기**됐다. → **iOS ContentState 를 백엔드 형식으로 통일**:

```swift
public struct ContentState: Codable, Hashable {
    public var phase: Phase            // analyzing | ready  (confirmed 는 로컬 선택 후 — push 엔 없음)
    public var needsReview: Bool
    public var summary: String
    public var candidates: [Candidate]
    public var selectedLabel: String?  // 로컬 선택 상태(push 미포함) — Codable 이라 decodeIfPresent
}
public struct Candidate: Codable, Hashable, Identifiable {
    public var id: String { label }
    public var intentType: String      // schedule|todo|knowledge|memo (구 intent)
    public var label: String
    public var reasoning: String       // 구 applicability 대체
}
```

- Codable CodingKeys 는 camelCase(`needsReview`, `intentType`) — 백엔드 payload 와 일치(백엔드도 camelCase 로 보냄).
- `selectedLabel` 은 백엔드 push 에 없으니 `init(from:)` 에서 `decodeIfPresent ?? nil`.
- **이 통일 없이 LA push 하면 decode 실패로 background 갱신 안 됨.** B6 에서 반드시.

---

## 2. B6 — LA production 재배선

### 2.1 리네임 (Mock* → Mochi*)
Tuist 는 `Sources/` glob 이라 **파일명 변경에 Project.swift 수정 불필요**. Read → 새 파일명 Write(수정 내용) → `rm` 기존 (git 이 rename 감지).

| 기존 | 신규 | 변경 |
|---|---|---|
| `Targets/Cores/CoreLiveActivity/Sources/MockUseCaseActivityAttributes.swift` (61줄) | `MochiLiveActivityAttributes.swift` | 타입명 + **`public let mochiItemID: UUID` 필드 추가** + ContentState/Candidate **§1 통일** |
| `Targets/Widgets/Sources/MockUseCaseLiveActivity.swift` (281줄) | `MochiLiveActivity.swift` | `struct MochiLiveActivity: Widget`, `ActivityConfiguration(for: MochiLiveActivityAttributes.self)`. **Widget UI 가 `candidate.intent`/`candidate.applicability` 참조 → `intentType`/`reasoning`**. ContentState `needsReview`/`summary` 활용 |
| `Targets/Widgets/Sources/MochiWidgetsBundle.swift` | (유지) | `MockUseCaseLiveActivity()` → `MochiLiveActivity()` |

**유지·치환만**:
- `Targets/Widgets/Sources/LiveActivityIntents.swift` (81줄): `Activity<MockUseCaseActivityAttributes>` → `Activity<MochiLiveActivityAttributes>` (L30 부근). `SelectCandidateIntent`(LA 선택 1급 — 핵심)·`OpenMochiOtherIntentIntent` 로직 유지.

### 2.2 LiveActivityCoordinator port (CorePersistence)
`Targets/Cores/CorePersistence/Sources/LiveActivityCoordinator.swift` (63줄):
- `LiveActivityCandidate`(L27-37) `{label, intent, applicability}` → **`{intentType, label, reasoning}`** (§1 통일, applicability 폐기).
- `liveActivityCaption(mochiItemID:body:)` (L59-63) 8-char hack **삭제** (mochiItemID 1급화로 불필요).
- protocol 시그니처(startAnalyzing/transitionToReady/endIfActive)는 유지.

### 2.3 LiveActivityCoordinatorLive (App) — push token 배선
`Targets/App/Sources/LiveActivityCoordinatorLive.swift` (118줄):
- attributes 타입명 전부 교체 (L7 doc·L25·L29·L35·L51·L63·L84·L85·L90·L91·L96·L99·L102·L108).
- attributes 생성 시 `mochiItemID:` 전달(§1 1급 필드).
- **`pushType: nil` → `.token`** (L36, L108) + 직후 `Task { for await tokenData in activity.pushTokenUpdates { ... POST /devices/push-token(kind:.liveActivity, mochiItemID:) } }`.
- **`findActivity(for:)`** (L83-88) `captureCaption.contains("[8char]")` → `activity.attributes.mochiItemID == mochiItemID` 정확 매칭.
- `startReadyAsFallback`(L94-117) caption hack 제거.
- **init 에 api/environment 주입**: `init(apiClient: any MochiAPIClient, environment: PushEnvironment)`. CorePersistence→CoreNetworking 의존 필요(또는 App 에서 closure 주입). `MochiApp.swift:42` `LiveActivityCoordinatorLive()` → `LiveActivityCoordinatorLive(apiClient: api, environment: pushEnv)` (api 는 `MochiApp.init:27` 의 `let api`, pushEnv `#if DEBUG .sandbox #else .production`).
- ContentState 생성 시 needsReview/summary/candidates(§1) 채움.

### 2.4 MochiItemSyncWorker — 전 채널 LA + candidate 매핑
`Targets/Cores/CorePersistence/Sources/MochiItemSyncWorker.swift` (369줄):
- **`uploadOne` (L76) `if mochiItem.source.channel == .screenshot` 가드 제거** → 모든 분석중 항목 LA 시작. caption hack 호출(L78-81) 제거, `mochiItemID` 직접 전달. caption "스크린샷 분석 중"(L80) → 채널 일반화.
- **`pollAnalysisOnce` (L274-288) `if item.source.channel == .screenshot` 가드 제거** → 전 채널 `.ready`. `demoteToManual` 경로 가드(L328 부근)도 동일.
- `transitionToReady` 호출 시 `item.analysis.reviewOptions` → `[LiveActivityCandidate(intentType:label:reasoning:)]` 매핑(§1 통일 필드).
- thumbnailRelativePath 는 비-스크린샷 nil — Widget UI 가 placeholder 렌더(안전, MochiLiveActivity 263-274 부근).

### 2.5 삭제
- `Targets/App/Sources/Prototype/MockUseCaseNotificationPrototype.swift` (211줄) — `rm`. 호출처 0 (MochiApp.swift:48 주석뿐, 다른 caller 없음 확인).
- `Targets/NotificationContent/` **전체** (`Sources/NotificationViewController.swift`·`MultiSelectCandidateView.swift`·`Support/Info.plist`·`Support/NotificationContent.entitlements`) — interactive notification 폐기(사용자 결정: LA 선택 1급, notification 은 일반 alert).
  - **`Project.swift`**: `MochiNotificationContent` 타겟 정의 블록 삭제(L443-459 부근) + App 타겟 dependencies 의 `.target(name: "MochiNotificationContent")` 삭제(L390 부근). scheme 은 NC 미참조(안전). 일반 alert 는 content extension 불필요 — 확정 결정과 정합.

### 2.6 검증
`tuist generate` 성공(NC 삭제 후 무결성) → `tuist build/test`(사용자 환경) → `bash .claude/scripts/ios-boundaries.sh` → `grep -rn MockUseCase Targets` 잔존 0.

---

## 3. B6½ — SSE live 구현 (foreground 폴링 대체)

### 3.1 신규 `LiveAgentStreamClient` (CoreAgentClient)
`Targets/Cores/CoreAgentClient/Sources/AgentStreamClient.swift` (21줄): protocol `stream(mochiItemID:)→AsyncThrowingStream<AgentEvent>`. `AgentEvent`: nodeEntered/toolStarted/toolFinished/partialSummary/**finalAnalysis(MochiItemAnalysis)**/failed. 현재 `AgentStreamClientDI.swift:6` `liveValue=NotConfiguredAgentStreamClient()`(throw).

신규 `LiveAgentStreamClient.swift`:
- `URLSession.bytes(for:)` + `.lines` 로 SSE 파싱 (`event:`/`data:` 누적 → 빈 줄 경계마다 디스패치).
- 백엔드 SSE 는 `event: node`(`{mochi_item_id,lifecycle_kind}`) / `event: final`(`{mochi_item_id,lifecycle_kind}`) / `event: failed`(`{message}`) 만 보낸다 — **분석결과는 안 보냄**.
- `event: final` 수신 → **`GET /mochi_items/{serverID}` 재조회**(`MochiAPIClient.getMochiItem`)로 `MochiItemDTO`→`MochiItemAnalysis` 매핑 → `.finalAnalysis(...)` emit 후 `continuation.finish()`. `node`→`.nodeEntered`, `failed`→`.failed`.
- 인증 Bearer 수기 주입(`AuthTokenProvider.bearerToken()`). baseURL init 주입.
- **GET 책임 레이어**: CoreAgentClient(이미 CoreNetworking 의존, `Project.swift:124-128` — boundary-legal).

### 3.2 주입 + SyncWorker 배선
- `AgentStreamClientDI`/`AppDependencies.swift:48`(TODO 주석 자리): `$0.agentStreamClient = LiveAgentStreamClient(baseURL: baseURL, tokenProvider: coordinator, apiClient: liveAPI)`. `resolveBaseURL()`(L52, private static — 노출 필요) 결과 `baseURL`(L23) 사용.
- `MochiItemSyncWorker`: foreground in-flight(`.uploaded` + `analysis==nil`) 항목 `stream` 구독 → `final`(GET 재조회 결과)에서 `applyAnalysis` + LA `.ready`(기존 L264-289 재사용, 전 채널) / `failed`→`demoteToManual`. **SSE 실패/끊김 → 기존 `startForegroundPolling`/`pollAnalysisOnce` fallback 유지**(제거 금지). `applyAnalysis` 세대 가드(L194 부근 `expectedUpdatedAt`)가 SSE/폴링 중복 적용 차단.
- `agentStreamClient` 를 SyncWorker init 주입(`@Dependency(\.agentStreamClient)`).

### 3.3 ⚠️ serverID 함정
SSE/GET 은 **serverID**(백엔드 PK)로 — 로컬 id GET 은 404(`MochiItemSyncWorker:248` 교훈). `MochiItemFeature.swift:34/46` 소비처는 `state.source.id`(로컬) 전달 — in-flight 완료 적용을 **SyncWorker 단일 소유**로 통일, MochiItemFeature SSE 는 진행표시(node/partial)용. 이중 적용은 세대 가드가 막음.

검증: `tuist test` + SSE 라인 파서 단위 테스트(`event:`/`data:`/멀티라인/빈줄 경계).

---

## 4. B7 — 알림 핸들러 + reconcile

`Targets/App/Sources/MochiAppDelegate.swift`(B5 에서 생성됨)에 추가:
- `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:)` → 알림 탭 → 앱 진입만(**후보 선택 action 없음** — 결정상 선택은 LA/앱 버킷). `userInfo["mochiItemID"]` → RootFeature 딥링크(상세/홈 버킷).
- `willPresent` → foreground 수신 시 `.banner, .sound`.
- **reconcile**: `MochiApp.swift:58-63` scenePhase `.active` → 기존 폴링에 더해 SSE 재연결 트리거(SyncWorker in-flight 재구독) + `pollAnalysisOnce()` 1회 (background push 로 변한 서버 상태 1회 동기화).

`RootFeature`(공유표면) 딥링크 진입 액션 추가 시 `MainTabFeature` 영향 — 최소 변경(기존 탭/상세 네비 재사용).

검증: `tuist test`. 실기(사용자): background 분석완료 → alert 도착 + LA `.ready` 갱신 + reconcile.

---

## 5. 검증 분담 + 잔여
- **Claude 직접(다음 세션)**: 코드 작성. `tuist generate`/`build`/`test` — **단 이 샌드박스는 xcodebuild `DVTBuildVersion` 제약으로 빌드 불가**. 사용자 환경 또는 빌드 가능 환경 필요. `ios-boundaries.sh`. SSE 파서 단위 테스트.
- **codex 리뷰**: B5 + B6~B7 각 단위. (사용자 지시: 작업 단위마다 codex.)
- **사용자(실기 필수)**: provisioning·`aps-environment`·APNs remote push·LA push·SSE 실기.
- **정합성 폭포(iOS 완료 시)**: `PRODUCT.md` 헷갈려요 UX(LA 선택 1급·전 채널·interactive notification 폐기 — **아직 미반영**) + iOS Widgets/App. `DOMAIN_DESIGN`/`ARCHITECTURE`/`TODO`/`openapi`/`CHANGELOG` 는 백엔드 단계에서 반영됨.
- **harvest**: iOS 완료 후 이 저널 + `2026-06-05-pr-b-live-activity-apns-handoff.md` + `2026-06-05-sharext-send-liveactivity-apns-memo-mode.md` 를 PRODUCT/ARCHITECTURE/DOMAIN 로 harvest 후 삭제(WORKFLOW §2.2).

## 6. 참조
- 백엔드 계약: `mochi-backend/app/modules/notifications/application/send_notification.py`(LA payload 형식 §1), `app/modules/agent/presentation/router.py`(SSE event 형식 §3.1).
- iOS 현황: §2~§4 의 모든 파일:줄.
- 결정: `2026-06-05-pr-b-live-activity-apns-handoff.md` §1 + 본 세션 사용자 결정(LA 선택 1급·전 채널·interactive notification 폐기·SSE 완료신호+GET 재조회·review_options DB 영속).
